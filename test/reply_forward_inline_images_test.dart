import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/services/inline_image_collector.dart';
import 'package:kaydet/data/services/smtp_service.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/domain/use_cases/email_html_codec.dart';
import 'package:kaydet/domain/use_cases/html_inline_processor.dart';
import 'package:kaydet/domain/use_cases/quoted_html.dart';

/// Yanıtla / İlet: orijinal HTML + gömülü görsel baytları + Content-ID
/// eşlemesi + doğru MIME gönderimi birlikte.
void main() {
  // Geçerli 1x1 PNG ve JPEG'e benzer ikinci bir yük (farklı bayt).
  const pngB64 =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
  final pngBytes = base64.decode(pngB64);
  final otherBytes = Uint8List.fromList([...pngBytes, 0, 1, 2, 3]);
  final otherB64 = base64.encode(otherBytes);

  String img(String b64, {String mime = 'image/png', int width = 120}) =>
      '<img src="data:$mime;base64,$b64" width="$width">';

  Iterable<String> imageSources(Delta delta) => delta
      .toList()
      .where((op) => op.data is Map && (op.data as Map)['image'] != null)
      .map((op) => (op.data as Map)['image'] as String);

  BuiltMessage build(String html, {List<String> attachments = const []}) {
    final result = MimeBuilder.build(
      OutgoingMessage(
        from: const EmailAddress(email: 'ben@ornek.com', name: 'Ben'),
        to: const [EmailAddress(email: 'alici@ornek.com')],
        subject: 'Yanıt',
        plainText: 'Yeni cevabım',
        html: html,
        attachmentPaths: attachments,
      ),
    );
    return (result as Ok<BuiltMessage>).value;
  }

  group('QuotedHtml', () {
    test('data: görseli belgeye girer, yanındaki metin korunur', () {
      final delta = QuotedHtml.toDelta(
        '<div>Merhaba</div><div>${img(pngB64)}</div><div>Hoşçakalın</div>',
        asQuote: false,
      )!;
      expect(imageSources(delta), ['data:image/png;base64,$pngB64']);
      final text = delta.toList().map((o) => o.data).whereType<String>().join();
      expect(text, contains('Merhaba'));
      expect(text, contains('Hoşçakalın'));
    });

    test('cid:, file:, blob: ve göreli yollar belgeye ASLA girmez', () {
      final delta = QuotedHtml.toDelta(
        '<p>Metin</p>'
        '<img src="cid:image001@example.com" width="100">'
        '<img src="file:///storage/emulated/0/a.png" width="100">'
        '<img src="/data/user/0/app/cache/a.png" width="100">'
        '<img src="attachments/123/image.png" width="100">'
        '<img src="blob:https://x/1" width="100">'
        '<img src="data:image/svg+xml;base64,PHN2Zy8+" width="100">',
        asQuote: false,
      )!;
      expect(imageSources(delta), isEmpty);
      final all = jsonEncode(delta.toJson());
      for (final leak in ['cid:', 'file:', '/data/user', 'attachments/', 'blob:']) {
        expect(all, isNot(contains(leak)));
      }
    });

    test('izleme pikseli ve gizli görseller atılır, uzak görsel kalır', () {
      final delta = QuotedHtml.toDelta(
        '<p>Metin</p>'
        '<img src="https://t.example.com/p.gif" width="1" height="1">'
        '<img src="https://t.example.com/q.gif" style="width:1px;height:1px">'
        '<img src="https://t.example.com/h.gif" style="display:none">'
        '<img src="https://cdn.example.com/banner.png" width="600">',
        asQuote: false,
      )!;
      expect(imageSources(delta), ['https://cdn.example.com/banner.png']);
    });

    test('genişlik yalnızca stilde verilmişse width özniteliğine taşınır', () {
      final delta = QuotedHtml.toDelta(
        '<img src="data:image/png;base64,$pngB64" style="width:240px">',
        asQuote: false,
      )!;
      final op = delta.toList().firstWhere((o) => o.data is Map);
      expect(op.attributes?['width'], 240);
    });

    test('Yanıtla satırları alıntı bloğuna alır, İlet almaz', () {
      const html = '<div>Orijinal metin</div>';
      final reply = QuotedHtml.toDelta(html, asQuote: true)!;
      final forward = QuotedHtml.toDelta(html, asQuote: false)!;
      expect(
        reply.toList().any((o) => o.attributes?['blockquote'] == true),
        isTrue,
      );
      expect(
        forward.toList().any((o) => o.attributes?['blockquote'] == true),
        isFalse,
      );
    });

    test('görünür içerik yoksa null döner (düz metne düşülür)', () {
      expect(
        QuotedHtml.toDelta('<style>p{}</style><div> </div>', asQuote: true),
        isNull,
      );
    });
  });

  group('HtmlInlineProcessor: data: → CID', () {
    test('her data: görseli Content-ID eşlemesiyle baytlarına çevrilir', () {
      final result = HtmlInlineProcessor.process(
        '<p>${img(pngB64)}</p><p>${img(otherB64, mime: 'image/jpeg')}</p>',
      );
      expect(result.inlines, hasLength(2));
      expect(result.html, isNot(contains('data:')));
      for (final inline in result.inlines) {
        expect(result.html, contains('src="cid:${inline.cid}"'));
      }
      expect(result.inlines[0].bytes, pngBytes);
      expect(result.inlines[0].mimeType, 'image/png');
      expect(result.inlines[0].filename, 'image001.png');
      expect(result.inlines[1].bytes, otherBytes);
      expect(result.inlines[1].mimeType, 'image/jpeg');
      expect(result.inlines[1].filename, 'image002.jpg');
      expect(result.inlines[0].cid, isNot(result.inlines[1].cid));
    });

    test('aynı görsel iki kez geçerse tek parça ve tek CID kullanılır', () {
      final result = HtmlInlineProcessor.process(
        '<p>${img(pngB64)}</p><p>${img(pngB64)}</p>',
      );
      expect(result.inlines, hasLength(1));
      final cid = result.inlines.single.cid;
      expect('src="cid:$cid"'.allMatches(result.html), hasLength(2));
    });

    test('bozuk ya da desteklenmeyen data: adresi alıcıya taşınmaz', () {
      final result = HtmlInlineProcessor.process(
        '<img src="data:image/png;base64,!!!bozuk!!!">'
        '<img src="data:image/svg+xml;base64,PHN2Zy8+">',
      );
      expect(result.inlines, isEmpty);
      expect(result.html, isNot(contains('data:')));
    });
  });

  group('SMTP MIME yapısı', () {
    String reply() =>
        '<div>Yeni cevabım</div><blockquote>${img(pngB64)}'
        '<div>${img(otherB64)}</div>${img(pngB64)}</blockquote>';

    test('görsel + ek yok: alternative → [plain, related → [html, görseller]]',
        () {
      final built = build(reply());
      final source = built.source;
      final root = built.mime;

      expect(root.mediaType.sub, em.MediaSubtype.multipartAlternative);
      expect(root.parts, hasLength(2));
      expect(root.parts![0].mediaType.sub, em.MediaSubtype.textPlain);
      final related = root.parts![1];
      expect(related.mediaType.sub, em.MediaSubtype.multipartRelated);
      // html + 2 benzersiz görsel (üçüncü aynı görsel tek parçayı paylaşır)
      expect(related.parts, hasLength(3));
      expect(related.parts![0].mediaType.sub, em.MediaSubtype.textHtml);

      expect(source, isNot(contains('data:image')));
      expect(built.mime.hasAttachments(), isFalse);
    });

    test('görsel + PDF: mixed → [alternative → [plain, related], ek]', () {
      final dir = Directory.systemTemp.createTempSync('kaydet_fwd_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final pdf = File('${dir.path}/fatura.pdf')
        ..writeAsBytesSync(utf8.encode('%PDF-1.4 sahte'));

      final built = build(reply(), attachments: [pdf.path]);
      final root = built.mime;

      expect(root.mediaType.sub, em.MediaSubtype.multipartMixed);
      expect(root.parts, hasLength(2));
      final alternative = root.parts![0];
      expect(alternative.mediaType.sub, em.MediaSubtype.multipartAlternative);
      expect(
        alternative.parts![1].mediaType.sub,
        em.MediaSubtype.multipartRelated,
      );
      expect(root.parts![1].decodeFileName(), 'fatura.pdf');

      // Yalnızca PDF ek sayılır; görseller gövdede kalır.
      final attachments = root.findContentInfo(
        disposition: em.ContentDisposition.attachment,
      );
      expect(attachments.map((a) => a.fileName), ['fatura.pdf']);
    });

    test('HTML’deki her cid: için aynı Content-ID’li görsel parçası vardır', () {
      final built = build(reply());
      final related = built.mime.parts![1];
      final html = related.parts![0].decodeContentText()!;
      final cidsInHtml = RegExp(
        r'cid:([^"]+)"',
      ).allMatches(html).map((m) => m.group(1)!).toSet();
      final cidsInMime = related.parts!
          .skip(1)
          .map((p) => p.getHeaderValue('content-id')!)
          .map((v) => v.replaceAll(RegExp('[<>]'), ''))
          .toSet();

      expect(cidsInHtml, isNotEmpty);
      expect(cidsInHtml, cidsInMime);
      for (final part in related.parts!.skip(1)) {
        expect(part.mediaType.top, em.MediaToptype.image);
        expect(
          part.getHeaderContentDisposition()?.disposition,
          em.ContentDisposition.inline,
        );
      }
    });

    test('gönder → Gönderilenler’den aç: görseller aynı baytlarla geri gelir',
        () {
      final built = build(reply());
      // Gönderilen kopya sunucudan yeniden indirilip ayrıştırılır.
      final received = em.MimeMessage.parseFromText(built.source);
      final html = received.decodeTextHtmlPart()!;
      final resolved = InlineImageCollector.resolve(received, html);

      expect(resolved, isNot(contains('cid:')));
      expect(resolved, contains('data:image/png;base64,$pngB64'));
      expect(resolved, contains('data:image/png;base64,$otherB64'));
    });

    test('düzenleyici → HTML → MIME hattı bütün olarak çalışır', () {
      // Orijinal ileti (alıcının aldığı hâl: cid çözülmüş data: görselli).
      final quoted = QuotedHtml.toDelta(
        '<div>Merhaba</div><div>${img(pngB64)}</div>',
        asQuote: true,
      )!;
      final composed = Delta()..insert('Yeni cevabım\n');
      for (final op in quoted.toList()) {
        composed.push(op);
      }
      final html = EmailHtmlCodec.encode(composed);

      final built = build(html);
      final received = em.MimeMessage.parseFromText(built.source);
      final resolved = InlineImageCollector.resolve(
        received,
        received.decodeTextHtmlPart()!,
      );
      expect(resolved, contains('Yeni cevabım'));
      expect(resolved, contains('Merhaba'));
      expect(resolved, contains('data:image/png;base64,$pngB64'));
    });
  });
}
