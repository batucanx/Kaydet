/// HTML → düz metin dönüşümü ve önizleme üretimi.
///
/// Gerçek maillerin çoğu HTML'dir. Liste satırındaki özet için HTML'i
/// ayrıştırmak pahalıdır; bu yüzden hafif, bağımlılıksız bir temizleyici
/// kullanılır. Detay ekranındaki tam render gerçek bir WebView ile
/// yapılır (bkz. `mail_detail_screen.dart` içindeki `_HtmlWebView`).
abstract final class TextExtraction {
  /// Atılan bloklar: `<script|style|head|title …> … </aynı etiket>`. Açılış
  /// etiketinin SONU (`>`) `_stripBlocks`ta `indexOf` ile bulunur: `[^>]*>`
  /// kuyruğu `>`sız çok sayıda açılış içeren bir iletide her açılışta belgenin
  /// sonuna dek taradığı için karesel süre alırdı.
  static final RegExp _blockOpen = RegExp(
    r'<(script|style|head|title)\b',
    caseSensitive: false,
  );
  static final Map<String, RegExp> _blockClose = {
    for (final name in const ['script', 'style', 'head', 'title'])
      name: RegExp('</$name\\s*>', caseSensitive: false),
  };
  static final RegExp _quoteHeader = RegExp(
    r'(yazdı|wrote|schrieb)\s*:$',
    caseSensitive: false,
  );
  static final RegExp _forwardHeader = RegExp(
    r'^-{3,}\s*(Orijinal|Original|İletilen|Forwarded)',
    caseSensitive: false,
  );
  static final RegExp _whitespaceRun = RegExp(r'\s+');
  static final RegExp _entityPattern = RegExp(
    r'&(#[xX][0-9a-fA-F]+|#\d+|[a-zA-Z][a-zA-Z0-9]*);',
  );
  static final RegExp _blockEnd = RegExp(
    r'</\s*(p|div|tr|li|h[1-6]|blockquote|table|section|article)\s*>',
    caseSensitive: false,
  );
  static final RegExp _lineBreak = RegExp(
    r'<\s*(br|hr)\s*/?\s*>',
    caseSensitive: false,
  );
  static final RegExp _manySpaces = RegExp(r'[ \t ]+');
  static final RegExp _manyNewlines = RegExp(r'\n{3,}');

  static const Map<String, String> _entities = {
    '&nbsp;': ' ',
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#39;': "'",
    '&apos;': "'",
    '&hellip;': '…',
    '&mdash;': '—',
    '&ndash;': '–',
    '&laquo;': '«',
    '&raquo;': '»',
    '&uuml;': 'ü',
    '&Uuml;': 'Ü',
    '&ouml;': 'ö',
    '&Ouml;': 'Ö',
    '&ccedil;': 'ç',
    '&Ccedil;': 'Ç',
    '&shy;': '',
    '&zwnj;': '',
  };

  /// HTML'i okunabilir düz metne çevirir.
  static String htmlToPlain(String html) {
    var text = html;
    text = _stripComments(text);
    text = _stripBlocks(text);
    text = text.replaceAll(_lineBreak, '\n');
    text = text.replaceAll(_blockEnd, '\n');
    text = _stripTags(text);
    text = decodeEntities(text);
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    text = text
        .split('\n')
        .map((line) => line.replaceAll(_manySpaces, ' ').trim())
        .join('\n');
    text = text.replaceAll(_manyNewlines, '\n\n');
    return text.trim();
  }

  /// Kalan etiketleri (`<…>`) boşlukla değiştirir; `<[^>]+>` ile aynı eşleşme
  /// kuralı, ama doğrusal sürede: `>`sız çok sayıda `<` içeren bir iletide regex
  /// her `<`de belgenin sonuna dek tarar ve karesel süre alırdı. `<>` (boş
  /// gövde) etiket sayılmaz; sonrasında hiç `>` kalmadıysa geri kalan metin
  /// olduğu gibi bırakılır.
  static String _stripTags(String text) {
    var open = text.indexOf('<');
    if (open == -1) return text;
    final out = StringBuffer();
    var position = 0;
    while (open != -1) {
      final close = text.indexOf('>', open + 1);
      if (close == -1) break;
      if (close == open + 1) {
        open = text.indexOf('<', close);
        continue;
      }
      out
        ..write(text.substring(position, open))
        ..write(' ');
      position = close + 1;
      open = text.indexOf('<', position);
    }
    out.write(text.substring(position));
    return out.toString();
  }

  /// `<!-- … -->` yorumlarını atar (yerine bir boşluk konur). Kapatılmamış bir
  /// `<!--` olduğu gibi kalır.
  ///
  /// `indexOf` ile doğrusal çalışır: `<!--.*?-->` regex'i kapatılmamış çok
  /// sayıda `<!--` içeren (kötü niyetli) bir iletide her açılış için belgenin
  /// sonuna dek yeniden tarar ve karesel süre alırdı.
  static String _stripComments(String html) {
    if (!html.contains('<!--')) return html;
    final out = StringBuffer();
    var position = 0;
    while (true) {
      final start = html.indexOf('<!--', position);
      if (start == -1) break;
      final end = html.indexOf('-->', start + 4);
      if (end == -1) break;
      out
        ..write(html.substring(position, start))
        ..write(' ');
      position = end + 3;
    }
    out.write(html.substring(position));
    return out.toString();
  }

  /// `<script>`, `<style>`, `<head>` ve `<title>` bloklarını (içerikleriyle)
  /// atar; her biri bir boşlukla değişir. Kapatılmamış bir blok olduğu gibi
  /// kalır.
  ///
  /// Bir etiket türü için kapanış BİR KEZ bulunamadıysa sonraki açılışlar için
  /// de yoktur: her açılışta belgenin sonuna dek yeniden aramak, kapatılmamış
  /// çok sayıda `<style>` içeren bir iletide karesel süre alırdı.
  static String _stripBlocks(String html) {
    final out = StringBuffer();
    final unclosed = <String>{};
    var position = 0;
    for (final open in _blockOpen.allMatches(html)) {
      // Az önce atılan bir bloğun içinde kalan (iç içe) açılışlar.
      if (open.start < position) continue;
      final name = open.group(1)!.toLowerCase();
      if (unclosed.contains(name)) continue;
      final tagEnd = html.indexOf('>', open.end);
      // Bundan sonra hiç `>` yoksa hiçbir açılış etiketi tamamlanamaz.
      if (tagEnd == -1) break;
      final close = _blockClose[name]!.allMatches(html, tagEnd + 1).firstOrNull;
      if (close == null) {
        unclosed.add(name);
        continue;
      }
      out
        ..write(html.substring(position, open.start))
        ..write(' ');
      position = close.end;
    }
    out.write(html.substring(position));
    return out.toString();
  }

  /// HTML varlıklarını çözer (adlandırılmış + sayısal).
  ///
  /// TEK geçişte çözülür: `&amp;` ayrıca ve önce çözülseydi `&amp;lt;`
  /// (metin olarak "&lt;") önce `&lt;`e, sonra `<`e dönüşür, yani iki kez
  /// çözülürdü. Tanınmayan varlıklar olduğu gibi kalır.
  static String decodeEntities(String input) =>
      input.replaceAllMapped(_entityPattern, (match) {
        final body = match.group(1)!;
        if (body.startsWith('#')) {
          final hex = body.length > 1 && (body[1] == 'x' || body[1] == 'X');
          final code = int.tryParse(
            hex ? body.substring(2) : body.substring(1),
            radix: hex ? 16 : 10,
          );
          // NUL ve yalnız vekil (surrogate) kod noktaları geçerli metin değildir.
          if (code == null ||
              code <= 0 ||
              code > 0x10FFFF ||
              (code >= 0xD800 && code <= 0xDFFF)) {
            return match.group(0)!;
          }
          return String.fromCharCode(code);
        }
        return _entities['&$body;'] ?? match.group(0)!;
      });

  /// Liste satırındaki özet metni.
  ///
  /// Alıntılanmış yanıt bloklarını ve imzaları atlar — kullanıcı için
  /// bilgi taşıyan kısım en üsttedir.
  static String buildPreview(String? plainText, {int maxLength = 140}) {
    if (plainText == null || plainText.trim().isEmpty) return '';
    final lines = plainText.split('\n');
    final kept = <String>[];

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      // Alıntı satırı
      if (line.startsWith('>')) continue;
      // İmza ayracı — sonrasındaki her şey imzadır
      if (line == '--' || line == '-- ') break;
      // "14 Eylül 2026 Pazartesi tarihinde X <a@b> yazdı:" gibi alıntı başlığı
      if (_quoteHeader.hasMatch(line)) break;
      if (_forwardHeader.hasMatch(line)) break;
      kept.add(line);
      if (kept.join(' ').length >= maxLength) break;
    }

    var preview = kept.join(' ').replaceAll(_whitespaceRun, ' ').trim();
    if (preview.isEmpty) {
      preview = plainText.replaceAll(_whitespaceRun, ' ').trim();
    }
    if (preview.length <= maxLength) return preview;
    return '${preview.substring(0, maxLength).trimRight()}…';
  }

  /// Yanıt gövdesi için alıntı bloğu üretir.
  static String quote(String plainText) => plainText
      .split('\n')
      .map((line) => line.isEmpty ? '>' : '> $line')
      .join('\n');

  /// E-posta kendi koyu temasını da getiriyor mu?
  ///
  /// `@media (prefers-color-scheme: dark)` içeren e-postalar (Apple Mail'e
  /// uyumlu modern şablonlar, sistem bildirimleri) koyu tasarımlarını kendileri
  /// taşır; bunlara ayrıca renk dönüşümü uygulamak tasarımcının paletini
  /// bozardı (bkz. `assets/web/mail_render.js`).
  static bool supportsDarkScheme(String html) => _prefersDark.hasMatch(html);

  static final RegExp _prefersDark = RegExp(
    r'prefers-color-scheme\s*:\s*dark',
    caseSensitive: false,
  );

  /// `prefers-color-scheme` medya sorgularını uygulamanın temasına sabitler.
  ///
  /// WebView bu sorguyu telefonun SİSTEM temasına göre değerlendirir; oysa
  /// Kaydet'in kendi tema tercihi var (sistem / açık / koyu / Outlook Koyu).
  /// Uygulama koyu ama telefon açıkken (ya da tersi) e-postanın koyu stilleri
  /// yanlış tarafta devreye girerdi. Sorgu uygulamanın temasıyla eşleşiyorsa
  /// her zaman doğru (`min-width: 0px`), eşleşmiyorsa her zaman yanlış
  /// (`max-width: 0px`) yapılır; medya sorgusunun geri kalanı (`and`, `not`,
  /// virgüllü listeler) olduğu gibi korunur.
  static String resolveColorSchemeQueries(String html, {required bool dark}) =>
      html.replaceAllMapped(_colorSchemeQuery, (m) {
        final wantsDark = m.group(1)!.toLowerCase() == 'dark';
        return wantsDark == dark ? '(min-width: 0px)' : '(max-width: 0px)';
      });

  static final RegExp _colorSchemeQuery = RegExp(
    r'\(\s*prefers-color-scheme\s*:\s*(dark|light)\s*\)',
    caseSensitive: false,
  );

  /// `<meta http-equiv="refresh">` etiketlerini kaldırır.
  ///
  /// Bu etiket iletiyi açar açmaz, kullanıcı hiçbir şeye dokunmadan başka bir
  /// adrese yönlendirir (oltalama/izleme). WebView'da bu gezinme harici
  /// tarayıcıyı kendiliğinden açardı.
  static String stripMetaRefresh(String html) => html.replaceAll(
    RegExp(
      r'<meta\b(?=[^>]*\bhttp-equiv\s*=\s*["\x27]?\s*refresh\b)[^>]*>',
      caseSensitive: false,
    ),
    '',
  );

  /// Kaynak e-postanın kendi `<meta name="viewport">` etiketini kaldırır.
  ///
  /// Bülten/kampanya e-postaları (Mailchimp, SendGrid vb. üretici araçlarla
  /// hazırlanmış) genellikle tam başlı-sonlu birer HTML belgesidir — kendi
  /// `<html><head>` bloğunda kendi viewport meta etiketini de taşırlar. Bu
  /// ham içerik `MailHtmlDocument.build`in gövdesine olduğu gibi
  /// gömülünce, HTML5 ayrıştırma kuralları gereği gövde içinde rastlanan
  /// `<meta>` etiketleri gerçek `<head>`'e taşınır ve bizim enjekte
  /// ettiğimiz etiketten SONRA gelir. Bir belgede birden çok viewport
  /// etiketi olduğunda tarayıcı SONUNCUYU esas alır — yani e-postanın
  /// kendi etiketi bizimkini sessizce ezer. Sonuç tam olarak bildirilen
  /// tutarsızlık: kendi viewport etiketi olmayan sade e-postalarda
  /// düzeltme işe yarar, üretici araçla hazırlanmış bültenlerde sanki hiç
  /// uygulanmamış gibi görünür. Sarmalamadan önce bu etiketi kaldırmak,
  /// bizim etiketimizin belgedeki TEK viewport etiketi olmasını garanti
  /// eder.
  static String stripViewportMeta(String html) => html.replaceAll(
    RegExp(
      r'<meta\b(?=[^>]*\bname\s*=\s*["\x27]viewport["\x27])[^>]*>',
      caseSensitive: false,
    ),
    '',
  );
}
