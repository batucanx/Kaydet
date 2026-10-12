import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart' as em;

import '../../domain/models/eml_models.dart';
import '../../domain/models/mail_models.dart';
import 'inline_image_collector.dart';
import 'mail_text_decoder.dart';

/// EML (.eml, RFC 822 / RFC 2822 / MIME) dosyalarını ayrıştıran ve
/// gerçek e-posta nesnesine (`EmlMessage`) dönüştüren production seviyesinde servis.
abstract final class EmlParserService {
  /// RFC 822 / MIME başlıklarını tanıyan regex deseni.
  static final RegExp _headerLineRegex = RegExp(
    r'^(?:Return-Path|Delivered-To|Received|Envelope-to|Delivery-date|ARC-[A-Za-z0-9-]+|DKIM-Signature|Authentication-Results|Message-ID|Message-Id|MIME-Version|X-[A-Za-z0-9-]+|From|To|Subject|Date|Content-Type|Content-Transfer-Encoding|Content-Disposition|Content-ID|Content-Id|Reply-To|Cc|Bcc|In-Reply-To|References)\s*:',
    caseSensitive: false,
  );

  /// Bir metnin veya dosyanın ham EML/RFC 822 e-posta içeriği olup olmadığını denetler.
  static bool looksLikeEmlText(String text) {
    if (text.trim().isEmpty) return false;
    final lines = text.split(RegExp(r'\r?\n')).take(30);
    for (final line in lines) {
      if (_headerLineRegex.hasMatch(line.trim())) {
        return true;
      }
    }
    // Başlıklar yapışmış olsa bile kontrol et
    return _headerLineRegex.hasMatch(text.trim());
  }

  /// Verilen bayt dizisinin EML olup olmadığını denetler.
  static bool looksLikeEmlBytes(Uint8List bytes) {
    if (bytes.isEmpty) return false;
    final previewLength = bytes.length < 2048 ? bytes.length : 2048;
    final sample = latin1.decode(bytes.sublist(0, previewLength));
    return looksLikeEmlText(sample);
  }

  /// Bir EML dosyasını senkron/asenkron olarak ana isolate'te ayrıştırır.
  static Future<EmlMessage> parseFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('EML dosyası bulunamadı.', filePath);
    }
    final bytes = await file.readAsBytes();
    return parseBytes(bytes);
  }

  /// Büyük EML dosyalarını ana UI thread'ini bloke etmemesi için ayrı bir
  /// background Isolate içinde ayrıştırır.
  static Future<EmlMessage> parseFileInIsolate(String filePath) {
    return Isolate.run(() async {
      final file = File(filePath);
      if (!file.existsSync()) {
        throw FileSystemException('EML dosyası bulunamadı.', filePath);
      }
      final bytes = file.readAsBytesSync();
      return parseBytes(bytes);
    });
  }

  /// Baytları ayrı Isolate'te ayrıştırır.
  static Future<EmlMessage> parseBytesInIsolate(Uint8List bytes) {
    return Isolate.run(() => parseBytes(bytes));
  }

  /// Ham baytlardan EML ayrıştırır. Encoding tespiti (UTF-8, ISO-8859-9, Windows-1254, Latin-1) yapar.
  static EmlMessage parseBytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const FormatException('EML dosyası boş.');
    }

    // Başlık bölümünden charset tespit etmeye çalış
    final headerSample = _extractHeaderSample(bytes);
    final charset = _detectCharsetFromSample(headerSample);

    String rawText;
    if (charset != null &&
        (charset == 'iso-8859-9' || charset == 'windows-1254')) {
      rawText = MailTextDecoderFallback.decodeWindows1254(bytes);
    } else {
      try {
        rawText = utf8.decode(bytes);
      } on FormatException {
        try {
          rawText = MailTextDecoderFallback.decodeWindows1254(bytes);
        } catch (_) {
          rawText = latin1.decode(bytes);
        }
      }
    }

    return parseText(rawText);
  }

  /// Ham metinden EML ayrıştırır.
  static EmlMessage parseText(String rawText) {
    var cleaned = rawText.replaceFirst('﻿', '').trimLeft();
    if (cleaned.isEmpty) {
      throw const FormatException('EML dosyası boş.');
    }

    // mbox tarzı "From sender@... date" başlangıç satırını temizle
    if (cleaned.startsWith('From ')) {
      final newlineIdx = cleaned.indexOf('\n');
      if (newlineIdx != -1) {
        cleaned = cleaned.substring(newlineIdx + 1).trimLeft();
      }
    }

    // MIME yapısını, çökmüş başlıkları, yapışmış boundary ve transfer encoding değerlerini onar
    cleaned = _repairEmlText(cleaned);

    em.MimeMessage? message;
    try {
      message = em.MimeMessage.parseFromText(cleaned.replaceAll('\n', '\r\n'));
    } catch (_) {
      // enough_mail parse edemezse manual fallback
    }

    if (message != null && message.mediaType.sub == em.MediaSubtype.messageRfc822) {
      final inner = message.decodeContentMessage();
      if (inner != null) {
        message = inner;
      }
    }

    if (message != null && _isValidParsedMessage(message)) {
      final domainMsg = _buildFromMimeMessage(message, cleaned);
      return _sanitizeLeakedHeaders(domainMsg);
    }

    // Manual RFC822 / MIME Fallback Parser
    return _manualParseRfc822(cleaned);
  }

  /// Satır sonları silinmiş, boundary'leri veya Content-Transfer-Encoding değerleri
  /// birbirine yapışmış bozuk EML metinlerini RFC 822 / MIME standartlarına uygun hâle getirir.
  static String _repairEmlText(String text) {
    var result = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    // 1. MIME Boundary tanımlarını bul (ör. boundary="tBxHeOogUFzSKxgR3Q")
    final boundaryMatches = RegExp(
      r'boundary\s*=\s*"?([^";\r\n]+)"?',
      caseSensitive: false,
    ).allMatches(result);
    final boundaries = boundaryMatches
        .map((m) => m.group(1)!.trim())
        .where((b) => b.isNotEmpty)
        .toSet();

    // 2. Birbirine yapışmış RFC 822 / MIME başlıklarını ("+0300Message-Id:", "Delivered-To: ...Received:") ayır
    final knownHeaders = RegExp(
      r'(?<=[^\n-])(?=(?:Return-Path|Delivered-To|Envelope-to|Delivery-date|ARC-[A-Za-z0-9-]+|DKIM-Signature|Authentication-Results|Message-ID|Message-Id|MIME-Version|X-[A-Za-z0-9-]+|From|Reply-To|In-Reply-To|References|Content-Type|Content-Transfer-Encoding|Content-Disposition|Content-ID|Content-Id|Cc|Bcc|To|Subject|Date)\s*:)',
      caseSensitive: false,
    );
    result = result.replaceAll(knownHeaders, '\n');

    // 3. Yapışmış MIME boundary sınırlarını ayır
    for (final boundary in boundaries) {
      final bndStart = RegExp('(?<=[^\\n])(?=--${RegExp.escape(boundary)})');
      result = result.replaceAll(bndStart, '\n');
      final bndClose = RegExp('(--${RegExp.escape(boundary)}--)(?=[^\\r\\n])');
      result = result.replaceAllMapped(bndClose, (m) => '${m.group(1)}\n');
      final bndNormal = RegExp('(--${RegExp.escape(boundary)})(?=[^\\r\\n-])');
      result = result.replaceAllMapped(bndNormal, (m) => '${m.group(1)}\n');
    }

    // 4. Content-Transfer-Encoding değerine yapışmış gövde veya boundary'leri temizle:
    // Örneğin "Content-Transfer-Encoding: 7bitt5--boundary" ->
    // "Content-Transfer-Encoding: 7bit\n\nt5\n--boundary"
    // Yatay boşluk [ \t] kullanarak \n üzerinden eşleşmeyi engelle.
    final cteGlued = RegExp(
      r'^(Content-Transfer-Encoding:[ \t]*(?:7bit|8bit|binary|quoted-printable|base64))[ \t]*([^\r\n]+)$',
      caseSensitive: false,
      multiLine: true,
    );
    result = result.replaceAllMapped(cteGlued, (m) {
      final header = m.group(1)!;
      final extra = m.group(2)!;
      if (extra.trim().isEmpty) return header;
      return '$header\n\n$extra';
    });

    // 5. Üst başlık bloğundaki satır katlamalarını (folding) düzelt:
    // Kolon `:` içermeyen continuation satırlarını önceki başlıkla birleştir
    int headerEnd = -1;
    if (boundaries.isNotEmpty) {
      for (final b in boundaries) {
        final idx = result.indexOf('--$b');
        if (idx != -1 && (headerEnd == -1 || idx < headerEnd)) {
          headerEnd = idx;
        }
      }
    }
    if (headerEnd == -1) {
      headerEnd = _findHeaderEndPosition(result);
    }

    if (headerEnd != -1) {
      final headerSection = result.substring(0, headerEnd);
      final rest = result.substring(headerEnd);

      final hLines = headerSection.split('\n');
      final unfoldedLines = <String>[];
      for (final line in hLines) {
        if (line.trim().isEmpty) {
          unfoldedLines.add(line);
          continue;
        }
        final isNewHeader = RegExp(r'^[A-Za-z0-9-]+:\s*').hasMatch(line.trim());
        if (!isNewHeader && unfoldedLines.isNotEmpty) {
          unfoldedLines.last = '${unfoldedLines.last} ${line.trim()}';
        } else {
          unfoldedLines.add(line);
        }
      }
      result = '${unfoldedLines.join('\n')}$rest';
    }

    // 6. Satır katlaması nedeniyle iki satıra bölünmüş RFC 2047 encoded-word'leri birleştir
    result = result.replaceAllMapped(
      RegExp(r'(=\?[^?\s]+\?[bBqQ]\?[^?\s]*)\n\s*([^?\s]*\?=)'),
      (m) => '${m.group(1)}${m.group(2)}',
    );

    // 7. Başlık bloğu ile gövde / ilk boundary arasında mutlaka çift satır sonu (\n\n) olmasını sağla
    if (boundaries.isNotEmpty) {
      for (final boundary in boundaries) {
        final firstBnd = '--$boundary';
        final bndIdx = result.indexOf(firstBnd);
        if (bndIdx != -1) {
          final beforeBnd = result.substring(0, bndIdx);
          if (!beforeBnd.endsWith('\n\n')) {
            result = '${beforeBnd.trimRight()}\n\n${result.substring(bndIdx)}';
          }
          break;
        }
      }
    } else {
      final hEnd = _findHeaderEndPosition(result);
      if (hEnd == -1) {
        final lines = result.split('\n');
        var lastHeaderIdx = -1;
        for (var i = 0; i < lines.length; i++) {
          final l = lines[i].trim();
          if (_headerLineRegex.hasMatch(l) ||
              l.startsWith(' ') ||
              l.startsWith('\t')) {
            lastHeaderIdx = i;
          } else if (l.isNotEmpty) {
            break;
          }
        }
        if (lastHeaderIdx != -1 && lastHeaderIdx + 1 < lines.length) {
          final headersPart = lines.sublist(0, lastHeaderIdx + 1).join('\n');
          final bodyPart = lines.sublist(lastHeaderIdx + 1).join('\n');
          result = '$headersPart\n\n$bodyPart';
        }
      }
    }

    return result;
  }

  static bool _isValidParsedMessage(em.MimeMessage msg) {
    final from = msg.from;
    final subject = msg.decodeSubject();
    final bodyText = msg.decodeTextPlainPart() ?? msg.decodeContentText();
    // Eğer hem from hem subject yoksa ve tüm metin tek bir düz body gibi algılanmışsa
    if ((from == null || from.isEmpty) && (subject == null || subject.isEmpty)) {
      if (bodyText != null && _headerLineRegex.hasMatch(bodyText.trim())) {
        return false;
      }
    }
    // Eğer gövdenin başında Return-Path, Received gibi sunucu üstbilgileri varsa ayrıştırma bozulmuştur
    if (bodyText != null && _startsWithTransportHeaders(bodyText.trim())) {
      return false;
    }
    return true;
  }

  static bool _startsWithTransportHeaders(String text) {
    final firstLine = text.split('\n').first.trim();
    return RegExp(
      r'^(?:Return-Path|Delivered-To|Received|DKIM-Signature|Authentication-Results|MIME-Version|X-[A-Za-z0-9-]+)\s*:',
      caseSensitive: false,
    ).hasMatch(firstLine);
  }

  /// Gövdeye sızmış teknik e-posta üstbilgilerini (Return-Path, Received vb.) temizler.
  static EmlMessage _sanitizeLeakedHeaders(EmlMessage msg) {
    var text = msg.textBody;
    var html = msg.htmlBody;
    if (text != null && _startsWithTransportHeaders(text.trim())) {
      text = _stripLeadingHeadersFromBody(text);
    }
    if (html != null && _startsWithTransportHeaders(html.trim())) {
      html = _stripLeadingHeadersFromBody(html);
    }
    if (text != msg.textBody || html != msg.htmlBody) {
      return EmlMessage(
        headers: msg.headers,
        body: EmlBody(
          textPlain: text,
          textHtml: html,
          isHtmlPreferred: html != null && html.trim().isNotEmpty,
        ),
        attachments: msg.attachments,
        rawSource: msg.rawSource,
      );
    }
    return msg;
  }

  static String _stripLeadingHeadersFromBody(String text) {
    final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    var idx = 0;
    while (idx < lines.length) {
      final line = lines[idx].trim();
      if (line.isEmpty) {
        idx++;
        break;
      }
      if (RegExp(r'^[A-Za-z0-9-]+:\s*').hasMatch(line) ||
          line.startsWith(' ') ||
          line.startsWith('\t')) {
        idx++;
        continue;
      }
      break;
    }
    return lines.sublist(idx).join('\n').trim();
  }

  static EmlMessage _buildFromMimeMessage(em.MimeMessage message, String rawSource) {
    // 1. Başlıklar
    final rawSubject = message.decodeSubject()?.trim() ?? message.getHeaderValue('subject')?.trim();
    final subject = (rawSubject != null && rawSubject.isNotEmpty)
        ? _decodeHeaderWord(rawSubject)
        : '(Konu yok)';

    final fromPart = message.from?.isNotEmpty == true ? message.from!.first : null;
    var fromEmail = fromPart?.email ?? '';
    var fromName = fromPart?.personalName?.trim() ?? '';
    final rawFromHeader = message.getHeaderValue('from');
    if (rawFromHeader != null && rawFromHeader.isNotEmpty) {
      final decodedFrom = _decodeHeaderWord(rawFromHeader);
      final parsedAddr = _parseSingleAddress(decodedFrom);
      if (fromEmail.isEmpty || fromEmail.contains('=?')) {
        fromEmail = parsedAddr.email;
      }
      if (fromName.isEmpty || fromName == fromEmail || fromName.contains('=?')) {
        fromName = parsedAddr.name ?? fromEmail;
      }
    }
    if (fromName.isEmpty) fromName = fromEmail.isNotEmpty ? fromEmail : 'Bilinmeyen Gönderici';
    fromName = _decodeHeaderWord(fromName);

    List<EmailAddress> parseAddresses(List<em.MailAddress>? addresses, String? rawHeader) {
      if (rawHeader != null && rawHeader.isNotEmpty) {
        final decoded = _decodeHeaderWord(rawHeader);
        final list = _parseAddressList(decoded);
        if (list.isNotEmpty) return list;
      }
      return addresses?.map((a) {
            final p = a.personalName?.trim();
            final name = (p != null && p.isNotEmpty) ? _decodeHeaderWord(p) : a.email;
            return EmailAddress(email: a.email, name: name);
          }).toList() ??
          const <EmailAddress>[];
    }

    final toList = parseAddresses(message.to, message.getHeaderValue('to'));
    final ccList = parseAddresses(message.cc, message.getHeaderValue('cc'));
    final bccList = parseAddresses(message.bcc, message.getHeaderValue('bcc'));

    final replyToPart = message.replyTo?.isNotEmpty == true ? message.replyTo!.first : null;
    final replyTo = replyToPart != null
        ? EmailAddress(
            email: replyToPart.email,
            name: (replyToPart.personalName?.trim().isNotEmpty == true)
                ? _decodeHeaderWord(replyToPart.personalName!.trim())
                : replyToPart.email,
          )
        : null;

    final messageId = message.getHeaderValue('message-id');
    final inReplyTo = message.getHeaderValue('in-reply-to');
    final references = message.getHeaderValue('references');
    final date = message.decodeDate() ?? DateTime.now();

    // 2. Gövde
    var rawHtml = MailTextDecoder.html(message);
    var textBody = MailTextDecoder.plain(message);

    if (rawHtml == null && textBody == null) {
      try {
        final contentText = message.decodeContentText();
        if (contentText != null && contentText.isNotEmpty) {
          if (message.mediaType.sub == em.MediaSubtype.textHtml) {
            rawHtml = contentText;
          } else {
            textBody = contentText;
          }
        }
      } catch (_) {}
    }

    // Eğer hâlâ boşsa, çocuk parçaları özyinelemeli olarak tara
    if (rawHtml == null && textBody == null && message.parts != null) {
      void findParts(em.MimePart part) {
        if (part.mediaType.sub == em.MediaSubtype.textHtml && rawHtml == null) {
          rawHtml = part.decodeContentText();
        } else if (part.mediaType.sub == em.MediaSubtype.textPlain && textBody == null) {
          textBody = part.decodeContentText();
        }
        if (part.parts != null) {
          for (final c in part.parts!) {
            findParts(c);
          }
        }
      }
      for (final child in message.parts!) {
        findParts(child);
      }
    }

    String? htmlBody;
    final validRawHtml = rawHtml;
    if (validRawHtml != null && validRawHtml.trim().isNotEmpty) {
      try {
        htmlBody = InlineImageCollector.resolve(message, validRawHtml);
      } catch (_) {
        htmlBody = validRawHtml;
      }
    }

    // 3. Ekler
    final attachments = <EmlAttachment>[];
    _extractAttachments(message, attachments);

    final headers = EmlHeaders(
      subject: subject,
      from: EmailAddress(email: fromEmail, name: fromName),
      to: toList,
      cc: ccList,
      bcc: bccList,
      replyTo: replyTo,
      messageId: messageId,
      inReplyTo: inReplyTo,
      references: references,
      date: date,
    );

    final body = EmlBody(
      textPlain: textBody,
      textHtml: htmlBody,
      isHtmlPreferred: htmlBody != null && htmlBody.trim().isNotEmpty,
    );

    return EmlMessage(
      headers: headers,
      body: body,
      attachments: attachments,
      rawSource: rawSource,
    );
  }

  static void _extractAttachments(em.MimeMessage message, List<EmlAttachment> result) {
    void processPart(em.MimePart part) {
      if (part == message) {
        if (part.parts != null) {
          for (final child in part.parts!) {
            processPart(child);
          }
        }
        return;
      }

      final mime = part.mediaType.text.toLowerCase();
      final sub = part.mediaType.sub;
      final top = part.mediaType.top;

      // Eğer multipart ise çocuklarına bak
      if (top == em.MediaToptype.multipart) {
        if (part.parts != null) {
          for (final child in part.parts!) {
            processPart(child);
          }
        }
        return;
      }

      final disp = (part.getHeaderValue('content-disposition') ?? '').toLowerCase();
      final isExplicitAttachment = disp.contains('attachment');
      final isInline = disp.contains('inline');
      final isRfc822 = mime.contains('rfc822') || sub == em.MediaSubtype.messageRfc822;
      final fileName = _getPartFileName(part);
      final hasFileName = fileName != null && fileName.isNotEmpty;

      // Body kontrolü: Eğer ek disposition'ı, dosya adı veya rfc822 yoksa
      // ve düz text/plain veya text/html ise ana gövdedir, ek değildir.
      if (!isExplicitAttachment &&
          !hasFileName &&
          !isRfc822 &&
          (sub == em.MediaSubtype.textPlain || sub == em.MediaSubtype.textHtml)) {
        return;
      }

      final isNested = isRfc822 || (fileName?.toLowerCase().endsWith('.eml') ?? false);

      Uint8List bytes;
      if (isNested) {
        final text = part.decodeContentText();
        if (text != null && text.isNotEmpty) {
          bytes = Uint8List.fromList(utf8.encode(text));
        } else {
          final bin = part.decodeContentBinary();
          if (bin != null && bin.isNotEmpty) {
            bytes = bin;
          } else {
            final buffer = StringBuffer();
            part.render(buffer);
            bytes = Uint8List.fromList(utf8.encode(buffer.toString()));
          }
        }
      } else {
        final encoding = (part.getHeaderValue('content-transfer-encoding') ?? '')
            .toLowerCase()
            .trim();
        if (part.mimeData is em.TextMimeData &&
            encoding != 'base64' &&
            encoding != 'b') {
          final text = part.decodeContentText();
          if (text != null && text.isNotEmpty) {
            bytes = Uint8List.fromList(utf8.encode(text));
          } else {
            final raw = (part.mimeData as em.TextMimeData).text;
            bytes = Uint8List.fromList(utf8.encode(raw));
          }
        } else {
          bytes = part.decodeContentBinary() ?? Uint8List(0);
        }
      }

      var safeName = _decodeHeaderWord(
        fileName ?? (isNested ? 'iletilen-mesaj.eml' : 'ek'),
      );
      if (isNested && !safeName.toLowerCase().endsWith('.eml')) {
        safeName = '$safeName.eml';
      }

      EmlMessage? nested;
      if (isNested && bytes.isNotEmpty) {
        try {
          nested = parseBytes(bytes);
        } catch (_) {}
      }

      final alreadyAdded = result.any((a) => a.fileName == safeName && a.sizeBytes == bytes.length);
      if (!alreadyAdded) {
        result.add(EmlAttachment(
          fileName: safeName,
          mimeType: mime.isNotEmpty
              ? mime
              : (isNested ? 'message/rfc822' : 'application/octet-stream'),
          sizeBytes: bytes.length,
          bytes: bytes,
          isInline: isInline && !isExplicitAttachment,
          contentId: part.getHeaderValue('content-id'),
          isNestedEml: isNested,
          nestedMessage: nested,
        ));
      }

      if (isNested) return;

      if (part.parts != null) {
        for (final child in part.parts!) {
          processPart(child);
        }
      }
    }

    processPart(message);
  }

  static String? _getPartFileName(em.MimePart part) {
    try {
      final decoded = part.decodeFileName();
      if (decoded != null && decoded.isNotEmpty) return decoded;
    } catch (_) {}

    final cd = part.getHeaderValue('content-disposition');
    if (cd != null) {
      final m = RegExp(r'filename\s*=\s*"?([^";\r\n]+)"?', caseSensitive: false).firstMatch(cd);
      if (m != null) return m.group(1)?.trim();
    }

    final ct = part.getHeaderValue('content-type');
    if (ct != null) {
      final m = RegExp(r'name\s*=\s*"?([^";\r\n]+)"?', caseSensitive: false).firstMatch(ct);
      if (m != null) return m.group(1)?.trim();
    }

    return null;
  }

  /// Tam teşekküllü fallback RFC 822 / MIME ayrıştırıcı:
  /// enough_mail'in gövde ve başlıkları ayıramadığı veya bozuk biçimli EML'lerde devreye girer.
  /// multipart/alternative yapısını, Content-Transfer-Encoding ve charset'leri bağımsız çözer.
  static EmlMessage _manualParseRfc822(String rawText) {
    final headerEndPos = _findHeaderEndPosition(rawText);
    String headerBlock;
    String bodyBlock;
    if (headerEndPos != -1) {
      headerBlock = rawText.substring(0, headerEndPos);
      bodyBlock = rawText.substring(headerEndPos).replaceFirst(RegExp(r'^\r?\n'), '');
    } else {
      headerBlock = rawText;
      bodyBlock = '';
    }

    final headersMap = <String, String>{};
    final lines = headerBlock.split(RegExp(r'\r?\n'));
    String? currentKey;
    for (final line in lines) {
      if (line.startsWith(' ') || line.startsWith('\t')) {
        if (currentKey != null) {
          headersMap[currentKey] = '${headersMap[currentKey] ?? ''} ${line.trim()}';
        }
      } else {
        final colonIdx = line.indexOf(':');
        if (colonIdx != -1) {
          currentKey = line.substring(0, colonIdx).trim().toLowerCase();
          final val = line.substring(colonIdx + 1).trim();
          headersMap[currentKey] = val;
        }
      }
    }

    final subject = _decodeHeaderWord(headersMap['subject'] ?? '(Konu yok)');
    final fromStr = headersMap['from'] ?? '';
    final from = _parseSingleAddress(_decodeHeaderWord(fromStr));
    final toList = _parseAddressList(_decodeHeaderWord(headersMap['to'] ?? ''));
    final ccList = _parseAddressList(_decodeHeaderWord(headersMap['cc'] ?? ''));
    final bccList = _parseAddressList(_decodeHeaderWord(headersMap['bcc'] ?? ''));
    final replyToStr = headersMap['reply-to'];
    final replyTo = replyToStr != null ? _parseSingleAddress(_decodeHeaderWord(replyToStr)) : null;
    final messageId = headersMap['message-id'];
    final inReplyTo = headersMap['in-reply-to'];
    final references = headersMap['references'];
    DateTime date = DateTime.now();
    if (headersMap.containsKey('date')) {
      try {
        date = em.DateCodec.decodeDate(headersMap['date']!) ?? DateTime.now();
      } catch (_) {}
    }

    final contentType = (headersMap['content-type'] ?? '').toLowerCase();
    if (contentType.contains('message/rfc822') &&
        headersMap['subject'] == null &&
        headersMap['from'] == null &&
        bodyBlock.trim().isNotEmpty) {
      return _manualParseRfc822(bodyBlock);
    }

    String? htmlBody;
    String? textBody;
    final attachments = <EmlAttachment>[];

    // Multipart denetimi
    final boundaryMatch = RegExp(
      r'boundary\s*=\s*"?([^";\r\n]+)"?',
      caseSensitive: false,
    ).firstMatch(contentType);

    if (boundaryMatch != null) {
      final boundary = boundaryMatch.group(1)!.trim();
      final parts = bodyBlock.split('--$boundary');
      for (var partStr in parts) {
        partStr = partStr.trim();
        if (partStr.isEmpty || partStr == '--') continue;
        final partEndPos = _findHeaderEndPosition(partStr);
        String partHeaders = '';
        String partBody = partStr;
        if (partEndPos != -1) {
          partHeaders = partStr.substring(0, partEndPos);
          partBody = partStr.substring(partEndPos).replaceFirst(RegExp(r'^\r?\n'), '');
        }
        final pMap = <String, String>{};
        for (final l in partHeaders.split(RegExp(r'\r?\n'))) {
          final c = l.indexOf(':');
          if (c != -1) {
            pMap[l.substring(0, c).trim().toLowerCase()] = l.substring(c + 1).trim();
          }
        }
        final pType = (pMap['content-type'] ?? '').toLowerCase();
        final pEnc = _extractTransferEncoding(pMap['content-transfer-encoding']);
        final pCharset = _extractCharset(pType);
        final decoded = _decodeBodyContent(partBody, pEnc, pCharset);

        final disp = (pMap['content-disposition'] ?? '').toLowerCase();
        final isAtt = disp.contains('attachment') || pType.contains('message/rfc822');

        if (isAtt) {
          final fnMatch = RegExp(r'filename\s*=\s*"?([^";\r\n]+)"?', caseSensitive: false)
              .firstMatch(disp);
          final fn = _decodeHeaderWord(fnMatch?.group(1)?.trim() ?? 'ek');
          final bytes = _decodeBodyBytes(partBody, pEnc);
          EmlMessage? nested;
          if (pType.contains('message/rfc822') || fn.endsWith('.eml')) {
            try {
              nested = parseBytes(bytes);
            } catch (_) {}
          }
          attachments.add(EmlAttachment(
            fileName: fn,
            mimeType: pType.isNotEmpty ? pType : 'application/octet-stream',
            sizeBytes: bytes.length,
            bytes: bytes,
            isNestedEml: nested != null,
            nestedMessage: nested,
          ));
        } else if (pType.contains('text/html')) {
          htmlBody ??= decoded;
        } else if (pType.contains('text/plain')) {
          textBody ??= decoded;
        }
      }
    } else {
      final enc = _extractTransferEncoding(headersMap['content-transfer-encoding']);
      final charset = _extractCharset(contentType);
      final decoded = _decodeBodyContent(bodyBlock, enc, charset);
      if (contentType.contains('text/html')) {
        htmlBody = decoded;
      } else {
        textBody = decoded;
      }
    }

    final headers = EmlHeaders(
      subject: subject,
      from: from,
      to: toList,
      cc: ccList,
      bcc: bccList,
      replyTo: replyTo,
      messageId: messageId,
      inReplyTo: inReplyTo,
      references: references,
      date: date,
      rawHeaders: headersMap,
    );

    return _sanitizeLeakedHeaders(EmlMessage(
      headers: headers,
      body: EmlBody(
        textPlain: textBody,
        textHtml: htmlBody,
        isHtmlPreferred: htmlBody != null && htmlBody.trim().isNotEmpty,
      ),
      attachments: attachments,
      rawSource: rawText,
    ));
  }

  /// Content-Transfer-Encoding değerini yalnızca kendi geçerli anahtar sözcüğünden okur.
  /// Yanına yapışmış boundary veya gövde metnini kesinlikle dahil etmez.
  static String _extractTransferEncoding(String? cte) {
    if (cte == null) return '7bit';
    final m = RegExp(
      r'\b(7bit|8bit|binary|quoted-printable|base64)\b',
      caseSensitive: false,
    ).firstMatch(cte);
    return m?.group(1)?.toLowerCase() ?? '7bit';
  }

  static String? _extractCharset(String contentType) {
    final m = RegExp(
      r'charset\s*=\s*"?([A-Za-z0-9_-]+)"?',
      caseSensitive: false,
    ).firstMatch(contentType);
    return m?.group(1)?.toLowerCase();
  }

  static String _decodeBodyContent(String content, String encoding, String? charset) {
    final clean = content.trim();
    if (encoding == 'base64') {
      try {
        final bytes = base64.decode(base64.normalize(clean.replaceAll(RegExp(r'\s+'), '')));
        return _decodeBytesWithCharset(bytes, charset);
      } catch (_) {}
    } else if (encoding == 'quoted-printable') {
      try {
        final bytes = MailTextDecoderFallback.decodeQuotedPrintable(clean);
        return _decodeBytesWithCharset(bytes, charset);
      } catch (_) {}
    } else if (charset != null && charset.isNotEmpty) {
      return _decodeBytesWithCharset(Uint8List.fromList(clean.codeUnits), charset);
    }
    return clean;
  }

  static Uint8List _decodeBodyBytes(String content, String encoding) {
    final clean = content.trim();
    if (encoding == 'base64') {
      try {
        return base64.decode(base64.normalize(clean.replaceAll(RegExp(r'\s+'), '')));
      } catch (_) {}
    } else if (encoding == 'quoted-printable') {
      try {
        return MailTextDecoderFallback.decodeQuotedPrintable(clean);
      } catch (_) {}
    }
    return Uint8List.fromList(utf8.encode(clean));
  }

  static int _findHeaderEndPosition(String text) {
    final idxCrlf = text.indexOf('\r\n\r\n');
    final idxLf = text.indexOf('\n\n');
    if (idxCrlf != -1 && idxLf != -1) {
      return idxCrlf < idxLf ? idxCrlf + 2 : idxLf + 1;
    }
    if (idxCrlf != -1) return idxCrlf + 2;
    if (idxLf != -1) return idxLf + 1;
    return -1;
  }

  static EmailAddress _parseSingleAddress(String raw) {
    final input = raw.trim();
    if (input.isEmpty) {
      return const EmailAddress(email: '', name: 'Bilinmeyen Gönderici');
    }
    final angle = RegExp(r'^(.*?)<([^<>]*)>\s*$').firstMatch(input);
    if (angle != null) {
      final email = angle.group(2)!.trim();
      var name = angle.group(1)!.trim();
      if (name.length >= 2 && name.startsWith('"') && name.endsWith('"')) {
        name = name.substring(1, name.length - 1).replaceAll(r'\"', '"');
      }
      name = _decodeHeaderWord(name.trim());
      return EmailAddress(
        email: email,
        name: name.isNotEmpty ? name : (email.isNotEmpty ? email : 'Bilinmeyen'),
      );
    }
    // "a@x.com (Ad Soyad)" veya yalın adres
    final comment = RegExp(r'^(\S+@\S+?)\s*\((.*)\)$').firstMatch(input);
    if (comment != null) {
      final name = _decodeHeaderWord(comment.group(2)!.trim());
      final email = comment.group(1)!;
      return EmailAddress(email: email, name: name.isNotEmpty ? name : email);
    }
    return EmailAddress(email: input, name: input);
  }

  static List<EmailAddress> _parseAddressList(String raw) {
    if (raw.trim().isEmpty) return const [];
    final parts = <String>[];
    final buf = StringBuffer();
    var inQuote = false;
    var inAngle = false;
    for (final ch in raw.split('')) {
      if (ch == '"') inQuote = !inQuote;
      if (!inQuote) {
        if (ch == '<') inAngle = true;
        if (ch == '>') inAngle = false;
      }
      if ((ch == ',' || ch == ';') && !inQuote && !inAngle) {
        parts.add(buf.toString());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    parts.add(buf.toString());
    return parts
        .where((p) => p.trim().isNotEmpty)
        .map(_parseSingleAddress)
        .where((a) => a.email.isNotEmpty)
        .toList();
  }

  /// RFC 2047 Encoded-Word (`=?charset?enc?text?=`) kod çözümlemesi yapar.
  /// Arka arkaya gelen encoded-word'leri birleştirir, soft break ve folding'i çözer.
  static String _decodeHeaderWord(String input) {
    if (!input.contains('=?') || !input.contains('?=')) return input;

    // RFC 2047 kuralı: Ardışık encoded-word'ler arasındaki boşluk atılır
    var text = input.replaceAll(RegExp(r'(\?=\s+=\?)'), '?==?');

    final regex = RegExp(r'=\?([^?]+)\?([bBqQ])\?([^?]+)\?=', caseSensitive: false);
    return text.replaceAllMapped(regex, (m) {
      final charset = m.group(1)!.toLowerCase();
      final encoding = m.group(2)!.toUpperCase();
      final encodedData = m.group(3)!;

      Uint8List bytes;
      if (encoding == 'B') {
        try {
          final clean = encodedData.replaceAll(RegExp(r'\s+'), '');
          bytes = base64.decode(base64.normalize(clean));
        } catch (_) {
          return m.group(0)!;
        }
      } else if (encoding == 'Q') {
        final clean = encodedData
            .replaceAll(RegExp(r'[\r\n]+'), '')
            .replaceAll('_', ' ');
        bytes = MailTextDecoderFallback.decodeQuotedPrintable(clean);
      } else {
        return m.group(0)!;
      }

      return _decodeBytesWithCharset(bytes, charset);
    });
  }

  static String _decodeBytesWithCharset(List<int> bytes, String? charset) {
    final cs = charset?.toLowerCase().trim() ?? 'utf-8';
    if (cs == 'iso-8859-9' || cs == 'windows-1254' || cs == 'cp1254') {
      return MailTextDecoderFallback.decodeWindows1254(Uint8List.fromList(bytes));
    }
    if (cs == 'iso-8859-1' || cs == 'latin1' || cs == 'latin-1') {
      return latin1.decode(bytes);
    }
    if (cs == 'us-ascii' || cs == 'ascii') {
      return ascii.decode(bytes, allowInvalid: true);
    }
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } catch (_) {
      try {
        return MailTextDecoderFallback.decodeWindows1254(Uint8List.fromList(bytes));
      } catch (_) {
        return latin1.decode(bytes);
      }
    }
  }

  static String _extractHeaderSample(Uint8List bytes) {
    final maxLen = bytes.length < 2048 ? bytes.length : 2048;
    return latin1.decode(bytes.sublist(0, maxLen)).toLowerCase();
  }

  static String? _detectCharsetFromSample(String headerSample) {
    final match = RegExp(r'charset\s*=\s*"?([a-zA-Z0-9_-]+)"?').firstMatch(headerSample);
    return match?.group(1)?.toLowerCase();
  }

  /// Dosya adını sanitize eder, Türkçe karakterleri korur, geçersiz karakterleri temizler.
  static String sanitizeEmlFileName(String subject, {DateTime? date, int index = 1}) {
    var clean = subject.trim();
    clean = clean.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();
    clean = clean.replaceAll(RegExp(r'\s+'), ' ');

    if (clean.isEmpty) {
      clean = 'mesaj-$index';
    }

    if (clean.length > 80) {
      clean = clean.substring(0, 80).trim();
    }

    if (date != null && !clean.contains(date.year.toString())) {
      clean = '$clean (${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')})';
    }

    if (!clean.toLowerCase().endsWith('.eml')) {
      clean = '$clean.eml';
    }

    return clean;
  }
}

/// Quoted-printable ve Windows-1254 Türkçe decoder yardımcı sınıfı.
abstract final class MailTextDecoderFallback {
  static Uint8List decodeQuotedPrintable(String input) {
    final bytes = <int>[];
    var i = 0;
    final chars = input.codeUnits;
    while (i < chars.length) {
      final c = chars[i];
      if (c == 0x3D /* = */) {
        // Yumuşak satır sonu (soft line break): =LF veya =CRLF
        if (i + 1 < chars.length && chars[i + 1] == 0x0A) {
          i += 2;
          continue;
        }
        if (i + 2 < chars.length &&
            chars[i + 1] == 0x0D &&
            chars[i + 2] == 0x0A) {
          i += 3;
          continue;
        }
        if (i + 2 < chars.length) {
          final h1 = _hexVal(chars[i + 1]);
          final h2 = _hexVal(chars[i + 2]);
          if (h1 >= 0 && h2 >= 0) {
            bytes.add((h1 << 4) | h2);
            i += 3;
            continue;
          }
        }
      }
      bytes.add(c);
      i++;
    }
    return Uint8List.fromList(bytes);
  }

  static int _hexVal(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;
    if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
    return -1;
  }

  static const _cp1254 = <int, int>{
    0x80: 0x20AC,
    0x85: 0x2026,
    0x91: 0x2018,
    0x92: 0x2019,
    0x93: 0x201C,
    0x94: 0x201D,
    0x96: 0x2013,
    0x97: 0x2014,
    0xD0: 0x011E, // Ğ
    0xDD: 0x0130, // İ
    0xDE: 0x015E, // Ş
    0xF0: 0x011F, // ğ
    0xFD: 0x0131, // ı
    0xFE: 0x015F, // ş
  };

  static String decodeWindows1254(Uint8List bytes) {
    return String.fromCharCodes([for (final b in bytes) _cp1254[b] ?? b]);
  }
}
