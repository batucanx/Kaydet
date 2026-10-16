import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../mail_detail/mail_html_document.dart';

/// Yanıtla / İlet'te alıntılanan iletinin orijinal HTML'ini WebView'da gösterir
/// ve kullanıcının DÜZENLEMESİNE izin verir (`contenteditable`). WebView
/// kurulamazsa (`onUnavailable`) çağıran düz editör önizlemesine düşer.
///
/// Düzenleme güvenle geri okunabilsin diye belge, okuma ekranının görüntü
/// dönüştürücü betiğini (koyu tema renk çevirisi, ölçekleme) KULLANMAZ; böylece
/// `innerHTML` özgün içerikten başka bir şey taşımaz. E-postalar beyaz zemin
/// için tasarlandığından zemin tema ne olursa olsun beyazdır.
class QuotedHtmlView extends StatefulWidget {
  const QuotedHtmlView({
    super.key,
    required this.header,
    required this.html,
    required this.onUnavailable,
    this.onChanged,
    this.height = 420,
  });

  final String header;
  final String html;
  final VoidCallback onUnavailable;

  /// Kullanıcı alıntıyı düzenledikçe (kısa bir gecikmeyle) güncel HTML'i bildirir.
  final ValueChanged<String>? onChanged;
  final double height;

  @override
  State<QuotedHtmlView> createState() => _QuotedHtmlViewState();
}

class _QuotedHtmlViewState extends State<QuotedHtmlView> {
  static const _channel = 'KaydetQuote';
  static final Set<Factory<OneSequenceGestureRecognizer>> _gestures = {
    Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
  };

  WebViewController? _controller;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      final header = const HtmlEscape()
          .convert(widget.header.trim())
          .replaceAll('\n', '<br>');
      final nonce = base64Url.encode(
        List<int>.generate(16, (_) => Random.secure().nextInt(256)),
      );
      final (prepared, _) = MailHtmlDocument.prepare(widget.html, dark: false);
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..enableZoom(true)
        ..setOverScrollMode(WebViewOverScrollMode.never)
        ..setBackgroundColor(Colors.white)
        ..addJavaScriptChannel(
          _channel,
          onMessageReceived: (m) => widget.onChanged?.call(m.message),
        )
        ..loadHtmlString(_buildDocument(header, prepared, nonce));
      final platform = controller.platform;
      if (platform is AndroidWebViewController) {
        unawaited(platform.setUseWideViewPort(true));
      }
      if (mounted) setState(() => _controller = controller);
    } on Object catch (e) {
      debugPrint('[QuotedHtmlView] WebView kurulamadı: $e');
      if (mounted) widget.onUnavailable();
    }
  }

  static String _buildDocument(String header, String body, String nonce) {
    return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="script-src 'nonce-$nonce'; object-src 'none'; base-uri 'none'; frame-src 'none'; form-action 'none'">
<meta name="viewport" content="width=device-width">
<style>
:root { color-scheme: light; -webkit-text-size-adjust: 100%; }
html { background: #fff; overflow-x: hidden; }
body { margin: 0; padding: 12px; color: #111; background: #fff; font-family: -apple-system, Roboto, sans-serif; font-size: 16px; overflow-wrap: break-word; overflow-x: hidden; }
img { max-width: 100%; height: auto; }
pre { white-space: pre-wrap; max-width: 100%; }
#kd-q { outline: none; min-height: 40px; display: flow-root; }
</style>
</head>
<body>
<div style="margin-bottom:8px;color:#555">$header</div>
<div id="kd-q" contenteditable="true">$body</div>
<script nonce="$nonce">
(function () {
  var q = document.getElementById('kd-q'), t = null, dirty = false;
  function send() {
    t = null;
    try { $_channel.postMessage(q.innerHTML); } catch (e) {}
  }
  q.addEventListener('input', function () {
    dirty = true;
    if (t) clearTimeout(t);
    t = setTimeout(send, 250);
  });
  q.addEventListener('blur', function () {
    if (t) { clearTimeout(t); t = null; }
    if (dirty) send();
  });
})();
</script>
</body>
</html>
''';
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return SizedBox(
      height: widget.height,
      child: controller == null
          ? const SizedBox.shrink()
          : WebViewWidget(controller: controller, gestureRecognizers: _gestures),
    );
  }
}
