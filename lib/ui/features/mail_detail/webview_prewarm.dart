import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// İlk mail açılışındaki takılmayı azaltır.
///
/// Sistem WebView'ı (Android'de Chromium) süreçte İLK kez oluşturulurken
/// kütüphaneyi yükler ve render sürecini başlatır; bu yüzden kullanıcının
/// açtığı ilk mail, sonrakilerden belirgin biçimde geç açılırdı. Uygulama
/// açıldıktan kısa süre sonra, boş bir sayfayla tek bir WebView oluşturup canlı
/// tutarız: sonraki (gerçek) WebView'lar hazır bir motora bağlanır. Yalnızca
/// ilk kare çizildikten SONRA çalışır, açılışı yavaşlatmaz.
abstract final class WebViewPrewarm {
  static WebViewController? _controller;

  static void schedule() {
    if (_controller != null) return;
    Timer(const Duration(seconds: 2), () {
      try {
        _controller = WebViewController()
          ..setJavaScriptMode(JavaScriptMode.disabled)
          ..loadHtmlString('<!DOCTYPE html><html><body></body></html>');
      } on Object catch (error) {
        // Ön ısıtma yalnızca bir iyileştirmedir; başarısız olsa da sorun değil.
        debugPrint('WebView ön ısıtma yapılamadı: $error');
      }
    });
  }
}
