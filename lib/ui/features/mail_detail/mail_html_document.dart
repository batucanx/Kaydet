import 'dart:convert';
import 'dart:math';

import 'package:flutter/painting.dart' show Color;
import 'package:flutter/services.dart' show rootBundle;

import '../../../domain/use_cases/text_extraction.dart';
import '../../core/theme/tokens.dart';

/// E-posta gövdesini WebView'a verilecek tam HTML belgesine sarar.
///
/// Belge dört şeyi birlikte kurar:
///
/// 1. **Viewport + temel CSS** — `width=device-width` ve metin/görsel için
///    güvenli varsayılanlar (`img { max-width: 100% }`, `text-size-adjust`).
///    `initial-scale` KASITLI olarak yazılmaz: sabit genişlikli bir düzen
///    akışkanlaştırılamazsa Android WebView'ın (`loadWithOverviewMode` +
///    `useWideViewPort`) "içeriği ekrana sığdır" davranışı devrede kalır;
///    `initial-scale=1` bunu kapatıp kullanıcıya yatay kaydırma bırakırdı.
///
/// 2. **Render betiği** (`assets/web/mail_render.js`) — sabit genişlikli
///    düzenleri ekrana sığdırır, küçük yazıları okunur tabana çıkarır ve koyu
///    temada renkleri Outlook mobil gibi "kısmi çevirme" ile dönüştürür.
///
/// 3. **CSP** — yalnızca bu belgeye özgü rastgele bir nonce'a izin verir; yani
///    çalışan tek betik yukarıdaki render betiğidir, e-postanın kendi
///    `<script>`leri, `on*=` olay nitelikleri ve `javascript:` adresleri
///    çalışmaz. `<iframe>` ve `<form>` gönderimi de kapalıdır (`frame-src`,
///    `form-action`): iletiyi açmak, kullanıcı dokunmadan başka bir sayfayı
///    yüklememeli/POST etmemeli. Kurum içi kullanımda bile dış göndericilerden (bülten,
///    tedarikçi) posta geldiği için bu emniyet kemeri çıkarılmaz; render'a
///    hiçbir etkisi yoktur.
///
/// 4. **Ölçü sarmalayıcısı** — gövde `<kd-root>` içine alınır. WebView kendi
///    içinde (yerel olarak) kaydırır; render betiği bu öğenin yüksekliğini
///    [layoutChannel] üzerinden YALNIZCA BİR KEZ, "içerik yerleşti" işareti
///    olarak bildirir. Belgenin `scrollHeight`'i bunun için kullanılamaz:
///    görünen alandan küçük olamaz ve `body { height: 100% }` gibi kurallarda
///    WebView'ın kendi boyunu geri döndürür. Webmail istemcileri (Gmail,
///    Outlook.com) de e-postayı bir sarmalayıcıya aldığından e-posta CSS'i buna
///    hazırdır.
///
/// 5. **Üst boşluk** — başlık (Flutter) gövdenin üstünde bir katman olduğu için
///    `<kd-root>`'tan önce, yüksekliği `--kd-top` CSS değişkeninden gelen bir
///    boşluk öğesi (`#kd-top`) durur. Değişkeni Flutter yazar; öğe satır içi
///    `!important` taşıdığından e-postanın kendi CSS'i onu ezemez.
abstract final class MailHtmlDocument {
  static const String _scriptAsset = 'assets/web/mail_render.js';

  /// Gövde yüksekliğinin bildirildiği JavaScript kanalının adı (WebView bu
  /// adla bir kanal kaydeder; betik `window[adı].postMessage` ile yazar).
  static const String layoutChannel = 'KaydetLayout';

  /// Metnin inebileceği en küçük yazı boyutu (px). Footer/dipnot metinleri
  /// masaüstü e-postalarda 9-11px ile yazılır; telefonda 12px'in altı okunmaz.
  static const int minFontPx = 12;

  /// Render betiğinin kaynağı; süreç boyunca bir kez okunur (bkz. `build`in
  /// `script` parametresi).
  static final Future<String> renderScript = rootBundle.loadString(
    _scriptAsset,
  );

  /// Düz metin gövdeyi [build]in göstereceği HTML'e çevirir: kaçışlar,
  /// satır sonları ve uzun satırlar korunur; http(s) adresleri bağlantı olur.
  static String fromPlainText(String plain) {
    final escaped = const HtmlEscape(HtmlEscapeMode.element).convert(plain);
    final linked = escaped.replaceAllMapped(
      RegExp(r'https?://[^\s<>"]+', caseSensitive: false),
      (m) => '<a href="${m[0]}">${m[0]}</a>',
    );
    return '<div style="white-space:pre-wrap;overflow-wrap:anywhere;">'
        '$linked</div>';
  }

  /// Ham e-posta HTML'ini [build]e verilecek gövdeye çevirir (regex temizliği;
  /// büyük gövdelerde ağırdır, bu yüzden çağıran bir isolate'ta çalıştırır).
  ///
  /// Kaynağın kendi viewport etiketi kaldırılır ki [build]in yazdığı etiket
  /// çakışmasız, belgedeki TEK viewport etiketi olsun (bkz.
  /// `TextExtraction.stripViewportMeta`). Görsel çözme (decode) ana iş
  /// parçacığını tutmasın diye `<img>`lere `decoding="async"` eklenir.
  /// İkinci değer e-postanın kendi koyu temasını getirip getirmediğidir.
  static (String body, bool emailSupportsDark) prepare(
    String html, {
    required bool dark,
  }) {
    final noConflictingViewport =
        TextExtraction.stripMetaRefresh(
          TextExtraction.stripViewportMeta(html),
        ).replaceAllMapped(
          RegExp(r'<img\b(?![^>]*\bdecoding\s*=)', caseSensitive: false),
          (m) => '<img decoding="async"',
        );
    return (
      TextExtraction.resolveColorSchemeQueries(
        noConflictingViewport,
        dark: dark,
      ),
      TextExtraction.supportsDarkScheme(noConflictingViewport),
    );
  }

  /// `body`: viewport temizliğinden geçmiş e-posta HTML'i.
  /// `emailSupportsDark`: e-posta kendi koyu temasını getiriyorsa (bkz.
  /// `TextExtraction.supportsDarkScheme`) renklerine dokunulmaz.
  /// `documentId`: yükseklik bildirimlerine eklenir; WebView, yerine yenisi
  /// yüklenmiş eski bir belgeden geç gelen bildirimi bununla ayıklar.
  static String build({
    required String body,
    required KaydetTokens tokens,
    required bool emailSupportsDark,
    required String script,
    required int documentId,
  }) {
    final dark = tokens.isDark;
    final nonce = _nonce();
    final config = jsonEncode({
      'dark': dark,
      'transform': dark && !emailSupportsDark,
      'bg': _rgb(tokens.readingBg),
      'text': _rgb(tokens.textPrimary),
      'minFont': minFontPx,
      'channel': layoutChannel,
      'doc': documentId,
      // WebView yerel kaydırdığı için içerik boyu Flutter'a yalnızca bir kez
      // ("içerik yerleşti" işareti olarak) bildirilir; sonrasında ölçüm ve
      // bildirim yapılmaz.
      'once': true,
    });

    return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="script-src 'nonce-$nonce'; object-src 'none'; base-uri 'none'; frame-src 'none'; form-action 'none'">
<meta name="viewport" content="width=device-width">
<style>
html { -webkit-tap-highlight-color: transparent; }
:root { color-scheme: ${dark ? 'dark' : 'light'}; -webkit-text-size-adjust: 100%; text-size-adjust: 100%; }
html { background: ${_hex(tokens.readingBg)}; overflow-x: hidden; }
body { margin: 0; padding: 16px; color: ${_hex(tokens.textPrimary)}; font-family: -apple-system, Roboto, sans-serif; overflow-wrap: break-word; overflow-x: hidden; }
a { overflow-wrap: anywhere; }
img { max-width: 100%; }
video, iframe, embed, object { max-width: 100%; }
img:not([width="1"]):not([height="1"]) { height: auto; }
pre { white-space: pre-wrap; overflow-wrap: anywhere; max-width: 100%; }
kd-root { display: flow-root; }
</style>
<script nonce="$nonce">window.__kaydet = $config;</script>
<script nonce="$nonce">
$script
</script>
</head>
<body><div id="kd-top" style="height:var(--kd-top,0px) !important;margin:0 !important;padding:0 !important;border:0 !important;overflow:hidden"></div><kd-root>$body</kd-root></body>
</html>
''';
  }

  /// CSP nonce'u: belge başına yeni, tahmin edilemez 128 bit.
  static String _nonce() {
    final random = Random.secure();
    return base64Url.encode(List<int>.generate(16, (_) => random.nextInt(256)));
  }

  static List<int> _rgb(Color color) {
    final argb = color.toARGB32();
    return [(argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF];
  }

  static String _hex(Color color) =>
      '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
}
