import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/domain/use_cases/quoted_html.dart';

/// Yanıtla / İlet'te orijinal HTML bozulmadan taşınır; yalnızca aktif içerik
/// ve taşınamayan görseller ayıklanır (bkz. `QuotedHtml.faithfulHtml`).
void main() {
  const png =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

  group('QuotedHtml.faithfulHtml', () {
    test('tablo, satır içi stil, buton ve bağlantı olduğu gibi kalır', () {
      const source =
          '<table width="600" style="background:#fff"><tr>'
          '<td style="padding:16px;text-align:center">'
          '<h1 style="color:#2a9d3f">Evrak eklendi!</h1>'
          '<a href="https://example.com/onay" '
          'style="background:#d00;color:#fff;padding:12px">Belgeyi onayla</a>'
          '</td></tr></table>';

      final out = QuotedHtml.faithfulHtml(source)!;

      expect(out, contains('<table'));
      expect(out, contains('style="background:#fff"'));
      expect(out, contains('color:#2a9d3f'));
      expect(out, contains('href="https://example.com/onay"'));
      expect(out, contains('background:#d00'));
      expect(out, contains('Evrak eklendi!'));
    });

    test('<head> içindeki <style> bloğu korunur', () {
      const source =
          '<html><head><style>.btn{background:#d00}</style></head>'
          '<body><a class="btn" href="https://x.test">Tıkla</a></body></html>';

      final out = QuotedHtml.faithfulHtml(source)!;

      expect(out, contains('<style>.btn{background:#d00}</style>'));
      expect(out, contains('class="btn"'));
    });

    test('betik, iframe, form ve olay öznitelikleri ayıklanır', () {
      const source =
          '<div onclick="steal()">Merhaba'
          '<script>alert(1)</script>'
          '<iframe src="https://evil.test"></iframe>'
          '<form action="https://evil.test"><input name="a"></form>'
          '<a href="javascript:alert(1)">kötü</a>'
          '<a href="https://iyi.test">iyi</a></div>';

      final out = QuotedHtml.faithfulHtml(source)!;

      expect(out, contains('Merhaba'));
      expect(out, isNot(contains('<script')));
      expect(out, isNot(contains('<iframe')));
      expect(out, isNot(contains('<form')));
      expect(out, isNot(contains('onclick')));
      expect(out, isNot(contains('javascript:')));
      expect(out, contains('href="https://iyi.test"'));
    });

    test('data: görseli korunur; cid:, file: ve izleme pikseli atılır', () {
      const source =
          '<p>Logo</p>'
          '<img src="data:image/png;base64,$png" width="120">'
          '<img src="cid:kayip@example.com" width="50">'
          '<img src="file:///storage/emulated/0/x.png">'
          '<img src="https://t.example.com/p.gif" width="1" height="1">'
          '<img src="https://cdn.example.com/banner.png" width="300">';

      final out = QuotedHtml.faithfulHtml(source)!;

      expect(out, contains('data:image/png;base64,$png'));
      expect(out, contains('https://cdn.example.com/banner.png'));
      expect(out, isNot(contains('cid:')));
      expect(out, isNot(contains('file:')));
      expect(out, isNot(contains('t.example.com')));
    });

    test('yalnızca görselden oluşan ileti boş sayılmaz', () {
      final out = QuotedHtml.faithfulHtml(
        '<img src="data:image/png;base64,$png" width="200">',
      );

      expect(out, isNotNull);
    });

    test('görünür içerik yoksa null döner', () {
      expect(QuotedHtml.faithfulHtml('<div>   </div>'), isNull);
      expect(QuotedHtml.faithfulHtml(''), isNull);
      expect(
        QuotedHtml.faithfulHtml(
          '<img src="https://t.example.com/p.gif" width="1" height="1">',
        ),
        isNull,
      );
    });
  });
}
