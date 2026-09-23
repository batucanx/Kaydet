import 'dart:convert';
import 'dart:math';

import 'package:flutter/painting.dart' show Color;
import 'package:flutter/services.dart' show rootBundle;

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
///    çalışmaz. Kurum içi kullanımda bile dış göndericilerden (bülten,
///    tedarikçi) posta geldiği için bu emniyet kemeri çıkarılmaz; render'a
///    hiçbir etkisi yoktur.
///
/// 4. **Ölçü sarmalayıcısı** — gövde `<kd-root>` içine alınır. Okuma
///    ekranında WebView kendi içinde kaydırmaz, boyu içeriğin boyuna eşitlenir;
///    render betiği bu öğenin yüksekliğini [layoutChannel] üzerinden bildirir.
///    Belgenin `scrollHeight`'i bunun için kullanılamaz: görünen alandan küçük
///    olamaz ve `body { height: 100% }` gibi kurallarda WebView'ın kendi
///    boyunu geri döndürür. Webmail istemcileri (Gmail, Outlook.com) de
///    e-postayı bir sarmalayıcıya aldığından e-posta CSS'i buna hazırdır.
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
      'bg': _rgb(tokens.bg),
      'text': _rgb(tokens.textPrimary),
      'minFont': minFontPx,
      'channel': layoutChannel,
      'doc': documentId,
    });

    return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="script-src 'nonce-$nonce'; object-src 'none'; base-uri 'none'">
<meta name="viewport" content="width=device-width">
<style>
:root { color-scheme: ${dark ? 'dark' : 'light'}; -webkit-text-size-adjust: 100%; text-size-adjust: 100%; }
html { background: ${_hex(tokens.bg)}; overflow-x: hidden; }
body { margin: 0; padding: 16px; color: ${_hex(tokens.textPrimary)}; font-family: -apple-system, Roboto, sans-serif; overflow-wrap: break-word; overflow-x: hidden; }
a { overflow-wrap: anywhere; }
img { max-width: 100%; }
img:not([width="1"]):not([height="1"]) { height: auto; }
pre { white-space: pre-wrap; }
kd-root { display: flow-root; }
</style>
<script nonce="$nonce">window.__kaydet = $config;</script>
<script nonce="$nonce">
$script
</script>
</head>
<body><kd-root>$body</kd-root></body>
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
