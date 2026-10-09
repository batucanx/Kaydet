import 'dart:convert';
import 'dart:io';

import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/services/signature_image_service.dart';
import 'package:kaydet/data/services/smtp_service.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/domain/use_cases/email_html_codec.dart';
import 'package:kaydet/domain/use_cases/html_inline_processor.dart';
import 'package:kaydet/domain/use_cases/signature_formatter.dart';

void main() {
  group('SignatureFormatter Tests', () {
    test('Text-only signature converts to Delta with text', () {
      const signature = SignatureRow(
        id: 1,
        accountId: 1,
        name: 'Kurumsal',
        body: 'Batuhan Can Aracı\nComputer Engineer',
        isDefault: true,
        imageType: 'none',
        localImagePath: null,
        remoteImageUrl: null,
        imageWidth: 200,
        imagePosition: 'bottom',
      );

      final delta = SignatureFormatter.toDelta(signature);
      expect(delta.isEmpty, isFalse);

      final plainText = delta.toList().map((op) => op.data.toString()).join();
      expect(plainText, contains('Batuhan Can Aracı'));
      expect(plainText, contains('Computer Engineer'));
    });

    test('Cihazdaki (galeri) görsel artık desteklenmez: yalnızca metin gömülür', () {
      // Eski sürümlerde galeriden eklenen görseller kaldırıldı (bkz.
      // `NewSignatureSheet.initState`); imza metni korunur, görsel yolu
      // iletiye taşınmaz.
      const signature = SignatureRow(
        id: 2,
        accountId: 1,
        name: 'Görsel İmza',
        body: 'İyi çalışmalar,',
        isDefault: false,
        imageType: 'local',
        localImagePath: 'C:/fake/path/signature.png',
        remoteImageUrl: null,
        imageWidth: 200,
        imagePosition: 'bottom',
      );

      final ops = SignatureFormatter.toDelta(signature).toList();

      // Görsel gömülmez; metin tek satır olarak korunur. Delta art arda
      // eklemeleri tek işlemde birleştirir, bu yüzden işlem sınırına değil
      // birleşik metne bakılır.
      expect(ops.any((op) => op.data is Map), isFalse);
      expect(ops.map((op) => op.data).join(), 'İyi çalışmalar,\n');
    });

    test('Remote image URL signature formats properly with top position', () {
      const testUrl = 'https://www.hasem.net/imza_silme/murat.png';
      const signature = SignatureRow(
        id: 3,
        accountId: 1,
        name: 'Remote İmza',
        body: 'Murat Bey\nŞirket Yöneticisi',
        isDefault: true,
        imageType: 'remote',
        localImagePath: null,
        remoteImageUrl: testUrl,
        imageWidth: 320,
        imagePosition: 'top',
      );

      final delta = SignatureFormatter.toDelta(signature);
      final ops = delta.toList();

      // Görsel en üstte olmalı (textten önce)
      final firstEmbedIndex = ops.indexWhere(
        (op) => op.data is Map && (op.data as Map)['image'] == testUrl,
      );
      expect(firstEmbedIndex, 0);

      final plainText = ops.map((op) => op.data.toString()).join();
      expect(plainText, contains('Murat Bey'));
    });

    test('Duplicate signature detection works for text and images', () {
      const signature = SignatureRow(
        id: 4,
        accountId: 1,
        name: 'Test',
        body: 'Benzersiz İmza Metni XYZ',
        isDefault: true,
        imageType: 'remote',
        localImagePath: null,
        remoteImageUrl: 'https://www.hasem.net/imza_silme/murat.png',
        imageWidth: 200,
        imagePosition: 'bottom',
      );

      const bodyWithText = 'Merhaba,\n\nBenzersiz İmza Metni XYZ\n';
      expect(SignatureFormatter.isAlreadyInserted(bodyWithText, signature), isTrue);

      const bodyDifferent = 'Farklı bir metin\n';
      expect(SignatureFormatter.isAlreadyInserted(bodyDifferent, signature), isFalse);

      const bodyWithImage = 'Merhaba <img src="https://www.hasem.net/imza_silme/murat.png" />';
      expect(SignatureFormatter.isAlreadyInserted(bodyWithImage, signature), isTrue);
    });

    test('Duplicate signature detection handles multiline JSON string format', () {
      const signature = SignatureRow(
        id: 5,
        accountId: 1,
        name: 'Haşem',
        body: '......\nHaşem Bilgi Teknolojileri',
        isDefault: true,
        imageType: 'remote',
        localImagePath: null,
        remoteImageUrl: 'https://www.hasem.net/imza_silme/murat.png',
        imageWidth: 200,
        imagePosition: 'bottom',
      );

      final delta = SignatureFormatter.toDelta(signature);
      final jsonStr = jsonEncode(delta.toJson());

      // Hem delta JSON formatında hem de düz metinde imza algılanmalı
      expect(SignatureFormatter.isAlreadyInserted(jsonStr, signature), isTrue);
      expect(
        SignatureFormatter.isAlreadyInserted(
          '......\nHaşem Bilgi Teknolojileri',
          signature,
        ),
        isTrue,
      );
    });

    test('Automatic and manual signature insertion produce identical rich Delta and HTML', () {
      const signature = SignatureRow(
        id: 6,
        accountId: 1,
        name: 'Test Logo',
        body: 'İyi çalışmalar,\nAhmet',
        isDefault: true,
        imageType: 'remote',
        remoteImageUrl: 'https://example.com/logo.png',
        localImagePath: null,
        imageWidth: 250,
        imagePosition: 'bottom',
      );

      final sigDelta = SignatureFormatter.toDelta(signature);

      // Delta görseli ve metni eksiksiz içermeli
      final ops = sigDelta.toList();
      expect(ops.any((op) => op.data is Map && (op.data as Map)['image'] == 'https://example.com/logo.png'), isTrue);
      expect(ops.any((op) => op.data is String && (op.data as String).contains('İyi çalışmalar,')), isTrue);

      final html = EmailHtmlCodec.encode(sigDelta);
      expect(html, contains('https://example.com/logo.png'));
      expect(html, contains('İyi çalışmalar,'));
      expect(html, contains('Ahmet'));
    });
  });

  group('EmailHtmlCodec Image Embed & Sanitizer Tests', () {
    test('Encodes Delta image embed to HTML <img> with width', () {
      final delta = Delta()
        ..insert('Saygılarımla,\n')
        ..insert(
          {'image': 'https://www.hasem.net/imza_silme/murat.png'},
          {'width': '200'},
        )
        ..insert('\n');

      final html = EmailHtmlCodec.encode(delta);
      expect(html, contains('<img src="https://www.hasem.net/imza_silme/murat.png"'));
      expect(html, contains('width="200"'));
    });

    test('Decodes HTML <img> tag into Delta image embed', () {
      const html = '<p>Saygılarımla,</p><p><img src="https://www.hasem.net/imza_silme/murat.png" width="200" /></p>';
      final delta = EmailHtmlCodec.decode(html);

      final ops = delta.toList();
      final hasImage = ops.any(
        (op) =>
            op.data is Map &&
            (op.data as Map)['image'] == 'https://www.hasem.net/imza_silme/murat.png',
      );
      expect(hasImage, isTrue);
    });

    test('ComposeDeltaSanitizer retains safe image embeds', () {
      final delta = Delta()
        ..insert('Metin\n')
        ..insert({'image': 'https://www.hasem.net/imza_silme/murat.png'}, {'width': '200'})
        ..insert('\n');

      final sanitized = ComposeDeltaSanitizer.sanitize(delta);
      final hasImage = sanitized.toList().any(
        (op) =>
            op.data is Map &&
            (op.data as Map)['image'] == 'https://www.hasem.net/imza_silme/murat.png',
      );
      expect(hasImage, isTrue);
    });
  });

  group('HtmlInlineProcessor & Security Tests', () {
    test('Local image path is converted to CID and NEVER exposed in HTML', () async {
      final tempDir = await Directory.systemTemp.createTemp('kaydet_sig_test');
      final tempFile = File('${tempDir.path}/test_sig.png');
      await tempFile.writeAsBytes(List.filled(100, 42));

      final localPath = tempFile.path;
      final rawHtml = '<p>Merhaba,</p><p><img src="$localPath" width="200" /></p>';

      final result = HtmlInlineProcessor.process(rawHtml);

      // KESİNLİKLE yerel dosya yolu HTML içinde bulunmamalı
      expect(result.html, isNot(contains(localPath)));
      expect(result.html, isNot(contains('file://')));
      expect(result.html, isNot(contains('kaydet_sig_test')));

      // CID formatında olmalı
      expect(result.html, contains('src="cid:'));
      expect(result.inlines.length, 1);
      expect(result.inlines.first.bytes.length, 100);
      expect(result.html, contains(result.inlines.first.cid));

      await tempDir.delete(recursive: true);
    });

    test('Remote image URL is preserved untouched and not converted to CID', () {
      const remoteUrl = 'https://www.hasem.net/imza_silme/murat.png';
      const rawHtml = '<p>Merhaba</p><p><img src="$remoteUrl" width="200" /></p>';

      final result = HtmlInlineProcessor.process(rawHtml);

      expect(result.html, contains('src="$remoteUrl"'));
      expect(result.inlines, isEmpty);
    });

    test('Non-existent local image path is stripped for safety and privacy', () {
      const nonExistentPath = 'C:/non_existent_dir_12345/secret_avatar.png';
      const rawHtml = '<p>Merhaba</p><p><img src="$nonExistentPath" width="200" /></p>';

      final result = HtmlInlineProcessor.process(rawHtml);

      expect(result.html, isNot(contains(nonExistentPath)));
      expect(result.inlines, isEmpty);
    });
  });

  group('MIME & SMTP Integration Tests', () {
    test('Local image produces multipart/mixed with inline image Content-ID header', () async {
      final tempDir = await Directory.systemTemp.createTemp('kaydet_mime_test');
      final tempFile = File('${tempDir.path}/avatar.png');
      await tempFile.writeAsBytes(List.filled(150, 99));

      final rawHtml = '<p>Selamlar</p><p><img src="${tempFile.path}" width="200" /></p>';

      final result = MimeBuilder.build(
        OutgoingMessage(
          from: const EmailAddress(email: 'sender@example.com', name: 'Test Gönderici'),
          to: const [EmailAddress(email: 'recipient@example.com')],
          subject: 'Görsel İmza Testi',
          plainText: 'Selamlar',
          html: rawHtml,
        ),
      );

      final built = (result as Ok<BuiltMessage>).value;
      final mimeSource = built.mime.renderMessage();

      // HTML içinde local path bulunmamalı
      expect(mimeSource, isNot(contains(tempFile.path)));
      expect(mimeSource, isNot(contains('kaydet_mime_test')));

      // CID ve inline attachment MIME başlıkları kontrolü
      expect(mimeSource, contains('Content-ID: <sig_'));
      expect(mimeSource, contains('Content-Disposition: inline'));
      expect(mimeSource, contains('filename="avatar.png"'));
      expect(mimeSource, contains('src="cid:sig_'));

      // E-posta istemcilerinin görseli ek/attachment değil gövde içi görmesi için
      expect(built.mime.hasAttachments(), isFalse);

      await tempDir.delete(recursive: true);
    });

    test('Remote image in email retains https src and has no MIME attachments', () {
      const remoteUrl = 'https://www.hasem.net/imza_silme/murat.png';
      const rawHtml = '<p>Selamlar</p><p><img src="$remoteUrl" width="200" /></p>';

      final result = MimeBuilder.build(
        OutgoingMessage(
          from: const EmailAddress(email: 'sender@example.com', name: 'Test Gönderici'),
          to: const [EmailAddress(email: 'recipient@example.com')],
          subject: 'Uzak Görsel İmza Testi',
          plainText: 'Selamlar',
          html: rawHtml,
        ),
      );

      final built = (result as Ok<BuiltMessage>).value;
      final mimeSource = built.mime.renderMessage();

      expect(mimeSource, contains('src="https://www.hasem.net/imza_silme/murat.png"'));
      expect(built.mime.hasAttachments(), isFalse);
    });
  });

  group('SignatureImageService Remote URL Validation', () {
    test('Rejects non-http protocols and malformed URLs', () {
      expect(SignatureImageService.isValidImageUrlFormat('ftp://evil.com/img.png'), isFalse);
      expect(SignatureImageService.isValidImageUrlFormat('javascript:alert(1)'), isFalse);
      expect(SignatureImageService.isValidImageUrlFormat('file:///C:/passwords.txt'), isFalse);
      expect(SignatureImageService.isValidImageUrlFormat('not a valid url'), isFalse);
    });

    test('Accepts valid HTTPS image URL structure', () {
      expect(
        SignatureImageService.isValidImageUrlFormat('https://www.hasem.net/imza_silme/murat.png'),
        isTrue,
      );
      expect(
        SignatureImageService.isValidImageUrlFormat('http://example.com/photo.jpeg'),
        isTrue,
      );
    });
  });
}
