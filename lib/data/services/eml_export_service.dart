import 'dart:io';
import 'package:enough_mail/enough_mail.dart' as em;

import '../../domain/models/mail_models.dart';
import '../database/app_database.dart';
import 'eml_parser_service.dart';

/// E-postaları .eml (RFC 822) dosyalarına dönüştüren ve toplu iletme (bulk forward)
/// için hazırlayan servis.
abstract final class EmlExportService {
  /// Bir `MessageRow` ve gövdesinden RFC 822 standardına uygun EML metni üretir.
  static Future<String> generateEmlSource({
    required MessageRow message,
    required MessageBodyRow? body,
    List<AttachmentRow> attachments = const [],
  }) async {
    final builder = em.MessageBuilder();

    // From
    builder.from = [em.MailAddress(message.fromName.isNotEmpty ? message.fromName : null, message.fromEmail)];

    // To
    final toList = EmailAddress.decodeList(message.toAddrJson);
    if (toList.isNotEmpty) {
      builder.to = toList.map((a) => em.MailAddress(a.name, a.email)).toList();
    }

    // Cc
    final ccList = EmailAddress.decodeList(message.ccJson);
    if (ccList.isNotEmpty) {
      builder.cc = ccList.map((a) => em.MailAddress(a.name, a.email)).toList();
    }

    // Bcc
    final bccList = EmailAddress.decodeList(message.bccJson);
    if (bccList.isNotEmpty) {
      builder.bcc = bccList.map((a) => em.MailAddress(a.name, a.email)).toList();
    }

    // Subject
    builder.subject = message.subject;

    // Date
    builder.date = message.dateUtc;

    // Message-ID
    if (message.messageIdHeader != null && message.messageIdHeader!.isNotEmpty) {
      var id = message.messageIdHeader!.trim();
      if (!id.startsWith('<')) id = '<$id';
      if (!id.endsWith('>')) id = '$id>';
      builder.messageId = id;
    }

    // In-Reply-To / References
    if (message.inReplyTo != null && message.inReplyTo!.isNotEmpty) {
      builder.setHeader('In-Reply-To', message.inReplyTo!);
    }
    if (message.referencesRaw != null && message.referencesRaw!.isNotEmpty) {
      builder.setHeader('References', message.referencesRaw!);
    }

    builder.setHeader('X-Mailer', 'KaydetMail');
    builder.setHeader('MIME-Version', '1.0');

    final htmlText = body?.html;
    final hasHtml = htmlText != null && htmlText.trim().isNotEmpty;
    var plainText = body?.plainText ?? '';
    // Gövde hiç indirilememişse (çevrimdışı vb.) .eml "metin içeriği yok"
    // görünmesin diye listedeki önizleme metni yedek olarak konur.
    if (plainText.trim().isEmpty && !hasHtml) {
      plainText = message.preview;
    }

    // Ek dosyaları oku
    final validFiles = <({AttachmentRow row, File file})>[];
    for (final att in attachments) {
      if (att.localPath != null) {
        final f = File(att.localPath!);
        if (f.existsSync()) {
          validFiles.add((row: att, file: f));
        }
      }
    }

    if (validFiles.isNotEmpty) {
      builder.setContentType(em.MediaType.fromSubtype(em.MediaSubtype.multipartMixed));
      if (hasHtml) {
        builder.addMultipartAlternative(plainText: plainText, htmlText: htmlText);
      } else {
        builder.addTextPlain(plainText);
      }

      for (final item in validFiles) {
        final bytes = item.file.readAsBytesSync();
        // İç içe .eml: base64 gövdeli `message/rfc822` geçersizdir ve
        // enough_mail'i çökertir; düz ikili ek olarak taşınır (ad `.eml`
        // kaldığı için ayrıştırıcı yine iç ileti olarak tanır).
        final isEml = item.row.fileName.toLowerCase().endsWith('.eml') ||
            item.row.mimeType.toLowerCase().contains('rfc822');
        final mediaType = isEml
            ? em.MediaType.fromSubtype(em.MediaSubtype.applicationOctetStream)
            : em.MediaType.guessFromFileName(item.row.fileName);
        builder.addBinary(bytes, mediaType, filename: item.row.fileName);
      }
    } else if (hasHtml) {
      builder.setContentType(em.MediaType.fromSubtype(em.MediaSubtype.multipartAlternative));
      builder.addTextPlain(plainText);
      builder.addTextHtml(htmlText);
    } else {
      // Tek parçalı düz metin: `addTextPlain` kökü `multipart/mixed` yapıp
      // tek çocuklu, geçersiz bir yapı üretir; `text` doğrudan text/plain yazar.
      builder
        ..text = plainText
        ..characterSet = em.CharacterSet.utf8
        ..transferEncoding = em.TransferEncoding.quotedPrintable;
    }

    final mimeMessage = builder.buildMimeMessage();
    return mimeMessage.renderMessage();
  }

  /// Tek bir iletiyi diske geçici bir .eml dosyası olarak yazar.
  static Future<File> exportMessageToEmlFile({
    required MessageRow message,
    required MessageBodyRow? body,
    List<AttachmentRow> attachments = const [],
    required Directory targetDirectory,
    int index = 1,
    String? rawSource,
  }) async {
    final fileName = EmlParserService.sanitizeEmlFileName(
      message.subject,
      date: message.dateUtc,
      index: index,
    );
    final targetFile = File('${targetDirectory.path}/$fileName');

    if (rawSource != null && rawSource.trim().isNotEmpty) {
      await targetFile.writeAsString(rawSource, flush: true);
    } else {
      final emlContent = await generateEmlSource(
        message: message,
        body: body,
        attachments: attachments,
      );
      await targetFile.writeAsString(emlContent, flush: true);
    }

    return targetFile;
  }

  /// Toplu iletme (Bulk Forward) için seçili iletileri .eml dosyalarına dönüştürür
  /// ve bu dosyaların yollarını döndürür.
  ///
  /// [ensureBody], gövdesi henüz indirilmemiş (yalnızca başlığı eşitlenmiş)
  /// iletiler için çağrılır; aksi hâlde .eml'in gövdesi boş üretilirdi.
  static Future<List<String>> prepareBulkForwardEmls({
    required List<MessageRow> messages,
    required AppDatabase db,
    Future<void> Function(int messageId)? ensureBody,
  }) async {
    final tempDir = await Directory.systemTemp.createTemp('kaydet_bulk_forward_');
    final paths = <String>[];
    final usedNames = <String>{};

    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      if (ensureBody != null) {
        try {
          await ensureBody(msg.id);
        } on Object {
          // Gövde indirilemezse eldeki verilerle (başlıklar) devam edilir.
        }
      }
      final body = await db.bodyOf(msg.id);
      final attachments = await db.attachmentsOf(msg.id);

      final baseName = EmlParserService.sanitizeEmlFileName(
        msg.subject,
        date: msg.dateUtc,
        index: i + 1,
      );

      // Aynı konulu iletilerde: "X.eml", "X (2).eml", "X (3).eml"
      final dotIdx = baseName.lastIndexOf('.');
      final prefix = dotIdx != -1 ? baseName.substring(0, dotIdx) : baseName;
      var uniqueName = baseName;
      var counter = 2;
      while (!usedNames.add(uniqueName.toLowerCase())) {
        uniqueName = '$prefix ($counter).eml';
        counter++;
      }

      final file = File('${tempDir.path}/$uniqueName');
      final content = await generateEmlSource(
        message: msg,
        body: body,
        attachments: attachments,
      );
      await file.writeAsString(content, flush: true);
      assert(() {
        // ignore: avoid_print
        print('[FORWARD MULTI] eml "$uniqueName" bytes=${file.lengthSync()}');
        return true;
      }());
      paths.add(file.path);
    }

    return paths;
  }
}
