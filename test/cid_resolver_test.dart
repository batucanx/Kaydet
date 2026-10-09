import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/services/inline_image_collector.dart';
import 'package:kaydet/domain/use_cases/cid_resolver.dart';

void main() {
  final bytes = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3]);
  final uri = 'data:image/png;base64,${base64.encode(bytes)}';
  final parts = {'logo@x.test': (mimeType: 'image/png', bytes: bytes)};

  group('CidResolver', () {
    test('src, background ve CSS url() başvurularını çözer; büyük/küçük harf ve %40 fark etmez', () {
      final html = CidResolver.resolve(
        '<img src="cid:logo@x.test">'
        '<img src="CID:Logo%40X.test">'
        '<td background="cid:logo@x.test">'
        '<div style="background:url(\'cid:logo@x.test\')"></div>'
        '<style>.a{background:url(cid:logo@x.test)}</style>',
        parts,
      );
      expect(html, isNot(contains('cid:')));
      expect(uri.allMatches(html), hasLength(5));
    });

    test('bilinmeyen başvuru ve cid ile bitişik sözcük dokunulmadan kalır', () {
      const source = '<img src="cid:baska@x.test"><p>acid:logo@x.test</p>';
      expect(CidResolver.resolve(source, parts), source);
    });

    test('parça yoksa HTML aynen döner', () {
      const source = '<img src="cid:logo@x.test">';
      expect(CidResolver.resolve(source, const {}), source);
    });
  });

  group('InlineImageCollector', () {
    String raw(String type, {String body = 'x'}) =>
        'From: a@x.test\r\nTo: b@x.test\r\nSubject: t\r\nMIME-Version: 1.0\r\n'
        'Content-Type: multipart/related; boundary="b"\r\n\r\n'
        '--b\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<img src="cid:logo@x.test">\r\n'
        '--b\r\nContent-Type: $type; name="l.bin"\r\nContent-Transfer-Encoding: base64\r\n'
        'Content-ID: <Logo@X.test>\r\nContent-Disposition: inline\r\n\r\n'
        '${base64.encode(bytes)}\r\n--b--\r\n';

    test('Content-ID\'li görsel parçası data: adresine dönüşür', () {
      final message = em.MimeMessage.parseFromText(raw('image/png'));
      final out = InlineImageCollector.resolve(
        message,
        '<img src="cid:logo@x.test">',
      );
      expect(out, '<img src="$uri">');
    });

    test('görsel olmayan parça gömülmez', () {
      final message = em.MimeMessage.parseFromText(raw('application/pdf'));
      const html = '<img src="cid:logo@x.test">';
      expect(InlineImageCollector.resolve(message, html), html);
    });
  });
}
