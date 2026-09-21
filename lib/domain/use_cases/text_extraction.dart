/// HTML → düz metin dönüşümü ve önizleme üretimi.
///
/// Gerçek maillerin çoğu HTML'dir. Liste satırındaki özet için HTML'i
/// ayrıştırmak pahalıdır; bu yüzden hafif, bağımlılıksız bir temizleyici
/// kullanılır. Detay ekranındaki tam render gerçek bir WebView ile
/// yapılır (bkz. `mail_detail_screen.dart` içindeki `_HtmlWebView`).
abstract final class TextExtraction {
  static final RegExp _scriptStyle = RegExp(
    r'<(script|style|head|title)[^>]*>.*?</\1\s*>',
    caseSensitive: false,
    dotAll: true,
  );
  static final RegExp _comments = RegExp(r'<!--.*?-->', dotAll: true);
  static final RegExp _blockEnd = RegExp(
    r'</\s*(p|div|tr|li|h[1-6]|blockquote|table|section|article)\s*>',
    caseSensitive: false,
  );
  static final RegExp _lineBreak = RegExp(
    r'<\s*(br|hr)\s*/?\s*>',
    caseSensitive: false,
  );
  static final RegExp _tags = RegExp(r'<[^>]+>');
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
    text = text.replaceAll(_comments, ' ');
    text = text.replaceAll(_scriptStyle, ' ');
    text = text.replaceAll(_lineBreak, '\n');
    text = text.replaceAll(_blockEnd, '\n');
    text = text.replaceAll(_tags, ' ');
    text = decodeEntities(text);
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    text = text
        .split('\n')
        .map((line) => line.replaceAll(_manySpaces, ' ').trim())
        .join('\n');
    text = text.replaceAll(_manyNewlines, '\n\n');
    return text.trim();
  }

  /// HTML varlıklarını çözer (adlandırılmış + sayısal).
  static String decodeEntities(String input) {
    var text = input;
    _entities.forEach((entity, value) {
      if (text.contains(entity)) text = text.replaceAll(entity, value);
    });
    text = text.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      final code = int.tryParse(m.group(1)!);
      if (code == null || code < 0 || code > 0x10FFFF) return m.group(0)!;
      return String.fromCharCode(code);
    });
    text = text.replaceAllMapped(RegExp(r'&#[xX]([0-9a-fA-F]+);'), (m) {
      final code = int.tryParse(m.group(1)!, radix: 16);
      if (code == null || code < 0 || code > 0x10FFFF) return m.group(0)!;
      return String.fromCharCode(code);
    });
    return text;
  }

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
      if (RegExp(
        r'(yazdı|wrote|schrieb)\s*:$',
        caseSensitive: false,
      ).hasMatch(line)) {
        break;
      }
      if (RegExp(
        r'^-{3,}\s*(Orijinal|Original|İletilen|Forwarded)',
        caseSensitive: false,
      ).hasMatch(line)) {
        break;
      }
      kept.add(line);
      if (kept.join(' ').length >= maxLength) break;
    }

    var preview = kept.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (preview.isEmpty) {
      preview = plainText.replaceAll(RegExp(r'\s+'), ' ').trim();
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
