import 'dart:io';

import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/services/smtp_service.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/domain/use_cases/email_html_codec.dart';

/// Üretilen HTML'in gerçek MIME katmanından (`MimeBuilder`) alıcıya bozulmadan
/// ulaşması.
///
/// HTML tek satırdır ve satır başına stil taşıdığı için uzundur; Türkçe
/// karakter, `&nbsp;` ve kaçışlanmış metin taşıma kodlamasından
/// (quoted-printable) sağ çıkmalıdır.
///
/// Yapı da sınanır: düz metin + HTML `multipart/alternative` olmalıdır. Eski
/// kod bunları `multipart/mixed` altında KARDEŞ parçalar olarak yolluyordu;
/// istemciler karışık parçaları art arda gösterdiği için alıcı iki gövdeyi
/// birden görebiliyordu, hangisinin çizileceği istemciye göre değişiyordu.
void main() {
  BuiltMessage build(
    String html, {
    String plain = 'düz metin',
    List<String> attachments = const [],
  }) {
    final result = MimeBuilder.build(
      OutgoingMessage(
        from: const EmailAddress(email: 'ben@ornek.com', name: 'Ben'),
        to: const [EmailAddress(email: 'alici@ornek.com')],
        subject: 'Biçim denemesi',
        plainText: plain,
        html: html,
        attachmentPaths: attachments,
      ),
    );
    return (result as Ok<BuiltMessage>).value;
  }

  Delta longDocument() {
    final delta = Delta();
    for (var i = 0; i < 120; i++) {
      delta
        ..insert('Satır $i: şğüöçıİ ', {'color': '#EF4444', 'size': '20'})
        ..insert('  çift  boşluk & <etiket> "tırnak" 😀')
        ..insert('\n', {'line-height': 1.5});
    }
    return delta;
  }

  /// Üst başlık bloğu (ilk boş satıra kadar).
  String headersOf(String source) => source.split('\r\n\r\n').first;

  test('HTML parçası çok uzun ve Türkçe içerikle bozulmadan ulaşır', () {
    final html = EmailHtmlCodec.encode(longDocument());
    expect(html.length, greaterThan(20000));

    final built = build(html);
    expect(built.mime.decodeTextHtmlPart(), html);
    expect(built.mime.decodeTextPlainPart(), 'düz metin');
  });

  test('hiçbir MIME satırı 998 karakteri aşmaz (RFC 5322)', () {
    final built = build(EmailHtmlCodec.encode(longDocument()));
    for (final line in built.source.split('\r\n')) {
      expect(line.length, lessThanOrEqualTo(998));
    }
  });

  test(
    'düz metin + HTML multipart/alternative olarak gider, mixed olarak değil',
    () {
      final built = build('<div>merhaba</div>');
      final headers = headersOf(built.source);

      expect(headers, contains('Content-Type: multipart/alternative'));
      expect(built.source, isNot(contains('multipart/mixed')));
      // Çok parçalı bir üst başlıkta taşıma kodlaması olmaz (eskiden
      // `base64` yazılıyordu, geçersizdi).
      expect(headers, isNot(contains('Content-Transfer-Encoding')));
      // En sadık biçim (HTML) SONA konur.
      expect(
        built.source.indexOf('text/plain'),
        lessThan(built.source.indexOf('text/html')),
      );
    },
  );

  test('ekli iletide kök mixed, alternatif çifti onun ilk çocuğudur', () {
    final dir = Directory.systemTemp.createTempSync('kaydet_mime_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/not.txt')..writeAsStringSync('ek içeriği');

    final html = EmailHtmlCodec.encode(longDocument());
    final built = build(html, attachments: [file.path]);
    final source = built.source;

    expect(headersOf(source), contains('Content-Type: multipart/mixed'));
    final alternative = source.indexOf('Content-Type: multipart/alternative');
    final attachment = source.indexOf('filename="not.txt"');
    expect(alternative, greaterThan(0));
    expect(attachment, greaterThan(alternative));
    // Ek, alternatifin İÇİNDE değil kardeşidir: HTML parçası ekten önce biter.
    expect(source.indexOf('text/html'), lessThan(attachment));

    expect(built.mime.decodeTextHtmlPart(), html);
    expect(built.mime.decodeTextPlainPart(), 'düz metin');
    expect(built.mime.hasAttachments(), isTrue);
  });

  test('HTML yoksa düz metin olarak gider (eski davranış korunur)', () {
    final result = MimeBuilder.build(
      const OutgoingMessage(
        from: EmailAddress(email: 'ben@ornek.com'),
        to: [EmailAddress(email: 'alici@ornek.com')],
        subject: 'düz',
        plainText: 'yalnızca metin',
      ),
    );
    final built = (result as Ok<BuiltMessage>).value;
    expect(built.source, isNot(contains('text/html')));
    expect(built.source, isNot(contains('multipart/alternative')));
    expect(built.mime.decodeTextPlainPart(), 'yalnızca metin');
  });

  test('gönderilen HTML editöre geri okununca aynı belge çıkar', () {
    final delta = longDocument();
    final built = build(EmailHtmlCodec.encode(delta));
    final received = built.mime.decodeTextHtmlPart()!;
    expect(EmailHtmlCodec.decode(received).toJson(), delta.toJson());
  });
}
