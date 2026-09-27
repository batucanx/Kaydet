import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/date_format.dart';
import 'package:kaydet/domain/use_cases/label_keywords.dart';
import 'package:kaydet/domain/use_cases/text_extraction.dart';

void main() {
  group('otomatik yönlendirme (meta refresh)', () {
    test('refresh etiketleri kaldırılır', () {
      const html =
          '<head><meta http-equiv="refresh" content="0;url=https://kotu.example">'
          '<META HTTP-EQUIV=refresh CONTENT="5">'
          "<meta http-equiv='Refresh' content='1'></head><p>Merhaba</p>";

      final cleaned = TextExtraction.stripMetaRefresh(html);

      expect(cleaned.toLowerCase(), isNot(contains('refresh')));
      expect(cleaned, contains('<p>Merhaba</p>'));
    });

    test('diğer meta etiketlerine dokunmaz', () {
      const html =
          '<meta charset="utf-8"><meta name="viewport" content="width=device-width">'
          '<meta http-equiv="Content-Type" content="text/html; charset=utf-8">';

      expect(TextExtraction.stripMetaRefresh(html), html);
    });
  });

  group('HTML varlıkları', () {
    test('çift çözülmez: `&amp;lt;` metin olarak "&lt;" kalır', () {
      expect(TextExtraction.decodeEntities('&amp;lt;b&amp;gt;'), '&lt;b&gt;');
      expect(TextExtraction.decodeEntities('&#38;amp;'), '&amp;');
    });

    test('adlandırılmış ve sayısal varlıklar tek geçişte çözülür', () {
      expect(TextExtraction.decodeEntities('&lt;b&gt; &amp; &quot;x&quot;'), '<b> & "x"');
      expect(TextExtraction.decodeEntities('&#214;zet &#x130;stanbul'), 'Özet İstanbul');
    });

    test('tanınmayan ve bozuk varlıklar olduğu gibi kalır', () {
      expect(TextExtraction.decodeEntities('&bilinmeyen; &#zz; &amp'), '&bilinmeyen; &#zz; &amp');
      expect(TextExtraction.decodeEntities('&#99999999;'), '&#99999999;');
    });
  });

  group('HTML → düz metin sağlamlığı', () {
    test('script/style/head/title blokları atılır, gövde kalır', () {
      const html =
          '<html><head><title>Başlık</title><style>p{color:red}</style></head>'
          '<body><script>alert(1)</script><p>Merhaba dünya</p></body></html>';

      expect(TextExtraction.htmlToPlain(html), 'Merhaba dünya');
    });

    test('`<header>` gibi head ile başlayan etiketler atılmaz', () {
      expect(
        TextExtraction.htmlToPlain('<header>Üst bilgi</header><p>Metin</p>'),
        contains('Üst bilgi'),
      );
    });

    test('yorumlar atılır, kapatılmamış yorum olduğu gibi kalır', () {
      expect(
        TextExtraction.htmlToPlain('Bir<!-- gizli -->İki'),
        'Bir İki',
      );
      expect(
        TextExtraction.htmlToPlain('Başı <!-- kapanmayan yorum'),
        contains('kapanmayan yorum'),
      );
    });

    test('kapatılmamış çok sayıda <style> karesel süre almaz', () {
      final html = '${'<style>a'.padRight(20, ' ') * 8000}<p>son</p>';
      final watch = Stopwatch()..start();

      final text = TextExtraction.htmlToPlain(html);

      watch.stop();
      expect(text, contains('son'));
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('etiketler atılır; kapanmayan `<` ve boş `<>` metin olarak kalır', () {
      expect(
        TextExtraction.htmlToPlain('<b>kalın</b> <i>eğik</i>'),
        'kalın eğik',
      );
      expect(TextExtraction.htmlToPlain('5 < 6'), '5 < 6');
      expect(TextExtraction.htmlToPlain('x <> y'), 'x <> y');
    });

    test('`>`sız çok sayıda `<` karesel süre almaz', () {
      final html = '<' * 300000;
      final watch = Stopwatch()..start();

      final text = TextExtraction.htmlToPlain(html);

      watch.stop();
      expect(text, html);
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('`>`sız çok sayıda <script açılışı karesel süre almaz', () {
      final html = '${'<script '.padRight(12, 'x') * 20000}<p>son</p>';
      final watch = Stopwatch()..start();

      final text = TextExtraction.htmlToPlain(html);

      watch.stop();
      expect(text, contains('son'));
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('kapatılmamış çok sayıda yorum karesel süre almaz', () {
      final html = '${'<!-- x '.padRight(12, ' ') * 8000}metin';
      final watch = Stopwatch()..start();

      final text = TextExtraction.htmlToPlain(html);

      watch.stop();
      expect(text, contains('metin'));
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });
  });

  group('liste gruplama başlığı', () {
    // Yerel saat dilimiyle kurulur: başlık takvim GÜNÜNE göre hesaplanır ve
    // UTC ile kurulan bir test, saat dilimi uçlarında gün sınırını kaydırırdı.
    final now = DateTime(2026, 9, 14, 12);

    test('bugün ve dün', () {
      expect(formatGroupHeader(DateTime(2026, 9, 14, 8), now: now), 'Bugün');
      expect(formatGroupHeader(DateTime(2026, 9, 13, 8), now: now), 'Dün');
    });

    test('gelecek tarihli ileti "Geçen Hafta" değil "Bugün" altında görünür', () {
      expect(formatGroupHeader(DateTime(2026, 9, 20, 8), now: now), 'Bugün');
    });

    test('eski iletiler değişmedi', () {
      expect(
        formatGroupHeader(DateTime(2026, 9, 10, 8), now: now),
        'Geçen Hafta',
      );
      expect(formatGroupHeader(DateTime(2026, 8, 20, 8), now: now), 'Bu Ay');
    });
  });

  group('etiket anahtar kelimesi', () {
    test('çakışma yoksa taban anahtar kelime döner', () {
      expect(uniqueLabelKeyword('Kişisel', const []), 'kaydet_kisisel');
      expect(uniqueLabelKeyword('Kişisel', const ['kaydet_is']), 'kaydet_kisisel');
    });

    test('aynı ASCII karşılığına düşen adlar ayrı anahtar kelime alır', () {
      expect(
        uniqueLabelKeyword('Kisisel', const ['kaydet_kisisel']),
        'kaydet_kisisel_2',
      );
      expect(
        uniqueLabelKeyword('Kişisel', const ['kaydet_kisisel', 'kaydet_kisisel_2']),
        'kaydet_kisisel_3',
      );
    });
  });
}
