import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/ui/core/theme/tokens.dart';
import 'package:kaydet/ui/features/mail_detail/mail_html_document.dart';

void main() {
  String doc({
    KaydetTokens tokens = KaydetTokens.dark,
    bool emailSupportsDark = false,
    String body = '<p>Merhaba</p>',
    int documentId = 1,
  }) => MailHtmlDocument.build(
    body: body,
    tokens: tokens,
    emailSupportsDark: emailSupportsDark,
    script: '/*render*/',
    documentId: documentId,
  );

  group('MailHtmlDocument', () {
    test('viewport yalnızca width=device-width içerir (initial-scale yok)', () {
      final html = doc();
      expect(
        html,
        contains('<meta name="viewport" content="width=device-width">'),
      );
      expect(html, isNot(contains('initial-scale')));
    });

    test('CSP yalnızca belgeye özgü nonce ile betiğe izin verir', () {
      final html = doc();
      final nonce = RegExp(
        r"script-src 'nonce-([^']+)'",
      ).firstMatch(html)!.group(1)!;
      expect(nonce, isNotEmpty);
      // Yapılandırma + render betiği: yalnızca bu ikisi nonce taşır.
      expect('<script nonce="$nonce">'.allMatches(html), hasLength(2));
      expect(html, contains("object-src 'none'"));
      // Her belge yeni bir nonce alır.
      expect(doc(), isNot(contains(nonce)));
    });

    test('koyu temada renk dönüşümü açılır', () {
      expect(doc(), contains('"transform":true'));
      expect(doc(), contains('color-scheme: dark'));
    });

    test('e-posta kendi koyu temasını getiriyorsa dönüşüm kapanır', () {
      expect(doc(emailSupportsDark: true), contains('"transform":false'));
    });

    test('açık temada dönüşüm kapalıdır', () {
      final html = doc(tokens: KaydetTokens.light);
      expect(html, contains('"transform":false'));
      expect(html, contains('color-scheme: light'));
    });

    test('tema renkleri ve gövde belgeye işlenir', () {
      final html = doc(
        tokens: KaydetTokens.outlookDark,
        body: '<p id="x">Selam</p>',
      );
      expect(
        html,
        contains('html { background: #000000; overflow-x: hidden; }'),
      );
      expect(html, contains('"bg":[0,0,0]'));
      expect(
        html,
        contains('<body><kd-root><p id="x">Selam</p></kd-root></body>'),
      );
    });

    test(
      'gövde ölçü sarmalayıcısında; kanal ve belge kimliği betiğe geçer',
      () {
        final html = doc(documentId: 7);
        expect(html, contains('kd-root { display: flow-root; }'));
        expect(html, contains('"channel":"${MailHtmlDocument.layoutChannel}"'));
        expect(html, contains('"doc":7'));
      },
    );
  });
}
