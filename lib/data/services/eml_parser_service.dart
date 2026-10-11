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
  /// RFC 822 başlıklarını tanıyan regex deseni.
  static final RegExp _headerLineRegex = RegExp(
    r'^(?:Return-Path|Received|DKIM-Signature|Authentication-Results|X-[A-Za-z0-9-]+|Message-ID|MIME-Version|From|To|Subject|Date|Content-Type|Reply-To|Cc|Bcc|In-Reply-To|References)\s*:',
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
    return false;
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
    if (charset != null && (charset == 'iso-8859-9' || charset == 'windows-1254')) {
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
    var cleaned = rawText.trimLeft();
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

    // Satır sonlarını RFC 822 uyumlu CRLF (\r\n) biçimine normalize et
    cleaned = cleaned.replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceAll('\n', '\r\n');

    em.MimeMessage? message;
    try {
      message = em.MimeMessage.parseFromText(cleaned);
    } catch (_) {
      // enough_mail parse edemezse manual fallback
    }

    if (message != null && _isValidParsedMessage(message)) {
      return _buildFromMimeMessage(message, cleaned);
    }

    // Manual RFC822 Fallback Parser
    return _manualParseRfc822(cleaned);
  }

  static bool _isValidParsedMessage(em.MimeMessage msg) {
    final from = msg.from;
    final subject = msg.decodeSubject();
    // Eğer hem from hem subject yoksa ve tüm metin tek bir düz body gibi algılanmışsa
    // enough_mail başlıkları gövdeden ayıramamış olabilir.
    if ((from == null || from.isEmpty) && (subject == null || subject.isEmpty)) {
      final bodyText = msg.decodeTextPlainPart() ?? msg.decodeContentText();
      if (bodyText != null && _headerLineRegex.hasMatch(bodyText.trim())) {
        return false;
      }
    }
    return true;
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

    final toList = message.to?.map((a) {
          final p = a.personalName?.trim();
          final name = (p != null && p.isNotEmpty) ? _decodeHeaderWord(p) : a.email;
          return EmailAddress(email: a.email, name: name);
        }).toList() ??
        const <EmailAddress>[];

    final ccList = message.cc?.map((a) {
          final p = a.personalName?.trim();
          final name = (p != null && p.isNotEmpty) ? _decodeHeaderWord(p) : a.email;
          return EmailAddress(email: a.email, name: name);
        }).toList() ??
        const <EmailAddress>[];

    final bccList = message.bcc?.map((a) {
          final p = a.personalName?.trim();
          final name = (p != null && p.isNotEmpty) ? _decodeHeaderWord(p) : a.email;
          return EmailAddress(email: a.email, name: name);
        }).toList() ??
        const <EmailAddress>[];

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

    String? htmlBody;
    if (rawHtml != null && rawHtml.trim().isNotEmpty) {
      try {
        htmlBody = InlineImageCollector.resolve(message, rawHtml);
      } catch (_) {
        htmlBody = rawHtml;
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
        bytes = part.decodeContentBinary() ?? Uint8List(0);
      }

      final safeName = _decodeHeaderWord(
        fileName ?? (isNested ? 'iletilen-mesaj.eml' : 'ek'),
      );

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
          mimeType: mime.isNotEmpty ? mime : (isNested ? 'message/rfc822' : 'application/octet-stream'),
          sizeBytes: bytes.length,
          bytes: bytes,
          isInline: isInline && !isExplicitAttachment,
          contentId: part.getHeaderValue('content-id'),
          isNestedEml: isNested,
          nestedMessage: nested,
        ));
      }

      // Nested EML ise, iç parçaları dış mesajın ek listesine dahil etme!
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

  /// Fallback RFC 822 ayrıştırıcı: enough_mail'in gövde ve başlıkları ayıramadığı
  /// veya bozuk biçimli EML'lerde devreye girer.
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
    final from = _parseSingleAddress(fromStr);
    final toList = _parseAddressList(headersMap['to'] ?? '');
    final ccList = _parseAddressList(headersMap['cc'] ?? '');
    final bccList = _parseAddressList(headersMap['bcc'] ?? '');
    final replyToStr = headersMap['reply-to'];
    final replyTo = replyToStr != null ? _parseSingleAddress(replyToStr) : null;
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
    String? htmlBody;
    String? textBody;

    if (contentType.contains('text/html')) {
      htmlBody = bodyBlock;
    } else {
      textBody = bodyBlock;
    }

    return EmlMessage(
      headers: EmlHeaders(
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
      ),
      body: EmlBody(textPlain: textBody, textHtml: htmlBody),
      attachments: const [],
      rawSource: rawText,
    );
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
    if (raw.trim().isEmpty) return const EmailAddress(email: '', name: 'Bilinmeyen Gönderici');
    final match = RegExp(r'^(?:"?([^"<]+)"?\s*)?<?([^>]+)>?$').firstMatch(raw.trim());
    if (match != null) {
      final name = match.group(1)?.trim();
      final email = match.group(2)?.trim() ?? '';
      return EmailAddress(
        email: email,
        name: (name != null && name.isNotEmpty)
            ? _decodeHeaderWord(name)
            : (email.isNotEmpty ? email : 'Bilinmeyen'),
      );
    }
    return EmailAddress(email: raw.trim(), name: raw.trim());
  }

  static List<EmailAddress> _parseAddressList(String raw) {
    if (raw.trim().isEmpty) return const [];
    final parts = raw.split(',');
    return parts.map(_parseSingleAddress).where((a) => a.email.isNotEmpty).toList();
  }

  /// RFC 2047 Encoded-Word (`=?charset?enc?text?=`) kod çözümlemesi yapar.
  static String _decodeHeaderWord(String input) {
    if (!input.contains('=?') || !input.contains('?=')) return input;

    final regex = RegExp(r'=\?([^?]+)\?([bBqQ])\?([^?]+)\?=', caseSensitive: false);
    return input.replaceAllMapped(regex, (m) {
      final charset = m.group(1)!.toLowerCase();
      final encoding = m.group(2)!.toUpperCase();
      final encodedData = m.group(3)!;

      Uint8List bytes;
      if (encoding == 'B') {
        try {
          bytes = base64.decode(base64.normalize(encodedData));
        } catch (_) {
          return m.group(0)!;
        }
      } else if (encoding == 'Q') {
        final clean = encodedData.replaceAll('_', ' ');
        bytes = MailTextDecoderFallback.decodeQuotedPrintable(clean);
      } else {
        return m.group(0)!;
      }

      if (charset == 'utf-8' || charset == 'utf8') {
        return utf8.decode(bytes, allowMalformed: true);
      } else if (charset == 'iso-8859-9' || charset == 'windows-1254') {
        return MailTextDecoderFallback.decodeWindows1254(bytes);
      } else {
        try {
          return utf8.decode(bytes);
        } catch (_) {
          return latin1.decode(bytes);
        }
      }
    });
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
    // / \ : * ? " < > | temizle
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
