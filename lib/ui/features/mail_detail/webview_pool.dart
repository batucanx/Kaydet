import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'mail_html_document.dart';

/// Bir mail WebView'ının denetleyicisi ve ekrana bağlanabilen geri çağrıları.
///
/// Denetleyici (Android'de yerel `WebView` nesnesi dahil) havuzda önceden
/// kurulur; kanal ve gezinme temsilcileri bu tutamağın DEĞİŞTİRİLEBİLİR
/// alanlarına yönlenir. Ekran denetleyiciyi devralınca yalnızca bu alanları
/// kendi metotlarına bağlar ([attach]).
final class MailWebViewHandle {
  MailWebViewHandle._(this.controller);

  final WebViewController controller;

  void Function(JavaScriptMessage message)? _onLayout;
  void Function(String url)? _onPageFinished;
  FutureOr<NavigationDecision> Function(NavigationRequest request)?
  _onNavigationRequest;

  /// Boş ısıtma sayfası yüklendi mi (havuzdaki yedek ancak o zaman verilir).
  bool _warm = false;
  bool _attached = false;

  void attach({
    required void Function(JavaScriptMessage message) onLayout,
    required void Function(String url) onPageFinished,
    required FutureOr<NavigationDecision> Function(NavigationRequest request)
    onNavigationRequest,
  }) {
    _attached = true;
    _onLayout = onLayout;
    _onPageFinished = onPageFinished;
    _onNavigationRequest = onNavigationRequest;
  }

  /// Ekran kapanırken: ölü bir `State`e geri çağrı gitmesin.
  void detach() {
    _onLayout = null;
    _onPageFinished = null;
    _onNavigationRequest = null;
  }
}

/// Mail WebView'ları için tek yedekli havuz.
///
/// Sorun: her mail ekranı kendi `WebViewController`ını kurar; Android'de bu,
/// yerel `WebView` nesnesinin yaratılması (Chromium'un ilk kullanımında
/// kütüphane yükleme ve render sürecini başlatma dahil) demektir ve ekran
/// açılırken ana iş parçacığında ödenirdi. Burada bir yedek denetleyici
/// önceden, boşta kurulur ve ısıtılır; ekran onu anında devralır, yerine
/// ekran açılışından SONRA yenisi kurulur.
///
/// Devralınan denetleyici ASLA havuza geri konmaz: bir `WebView` yerel görünüm
/// hiyerarşisinden bir kez ayrıldıktan sonra yeni bir platform görünümüne
/// güvenle yeniden takılamaz. Bu yüzden havuz "geri dönüşüm" değil "önceden
/// üretim" havuzudur.
abstract final class WebViewPool {
  static MailWebViewHandle? _spare;
  static Timer? _timer;

  /// Yedeği yeniden kurmadan önce beklenen süre: ekranın giriş geçişi ve ilk
  /// yükleme bitsin, kurulum onlarla yarışmasın.
  static const Duration _refillDelay = Duration(milliseconds: 1500);

  /// Uygulama açıldıktan sonra ilk yedeği kurar (ilk kare çizildikten sonra,
  /// açılışı yavaşlatmaz).
  static void schedule() => _scheduleRefill(const Duration(seconds: 2));

  /// Kullanıma hazır bir tutamak verir. Yedek yoksa ya da henüz ısınmadıysa
  /// yenisi eşzamanlı kurulur (havuzsuz eski davranış); her durumda bir sonraki
  /// yedek arka planda planlanır.
  static MailWebViewHandle acquire() {
    final spare = _spare;
    final MailWebViewHandle handle;
    if (spare != null && spare._warm && !spare._attached) {
      _spare = null;
      handle = spare;
    } else {
      handle = _create();
    }
    _scheduleRefill(_refillDelay);
    return handle;
  }

  static void _scheduleRefill(Duration delay) {
    _timer?.cancel();
    if (_spare != null) return;
    _timer = Timer(delay, () {
      if (_spare != null) return;
      try {
        final handle = _create();
        _spare = handle;
        unawaited(
          handle.controller.loadHtmlString(
            '<!DOCTYPE html><html><body></body></html>',
          ),
        );
      } on Object catch (error) {
        // Havuz yalnızca bir iyileştirmedir; başarısız olsa ekranlar kendi
        // denetleyicilerini kurar.
        debugPrint('WebView havuzu kurulamadı: $error');
      }
    });
  }

  static MailWebViewHandle _create() {
    // `_create` yürütülürken tutamak henüz yok; temsilciler ona kapanış
    // üzerinden erişir.
    late final MailWebViewHandle handle;

    // JS açık: çalışan tek betik `MailHtmlDocument`in nonce'lu render
    // betiğidir; e-postanın kendi betikleri belgedeki CSP ile engellenir.
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..enableZoom(true)
      ..setVerticalScrollBarEnabled(false)
      ..setOverScrollMode(WebViewOverScrollMode.never)
      ..addJavaScriptChannel(
        MailHtmlDocument.layoutChannel,
        onMessageReceived: (message) => handle._onLayout?.call(message),
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) {
            if (handle._attached) {
              handle._onPageFinished?.call(url);
            } else {
              handle._warm = true;
            }
          },
          onNavigationRequest: (request) {
            final handler = handle._onNavigationRequest;
            if (handler != null) return handler(request);
            // Devralınmadan önce yalnızca ısıtma belgesi (`about:`) yüklenir.
            return request.url.startsWith('about:')
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
        ),
      );

    // Android WebView varsayılanında `useWideViewPort` kapalıdır ve bu
    // durumda `<meta name="viewport">` tamamen yok sayılıp gövde sabit
    // masaüstü genişliğinde (~980px) render edilir. Açınca viewport etiketi
    // (bkz. `MailHtmlDocument`) uygulanır ve ileti telefon genişliğine sığdırılır.
    // iOS'ta WKWebView viewport'u zaten doğru uygular.
    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      unawaited(platform.setUseWideViewPort(true));
    }

    handle = MailWebViewHandle._(controller);
    return handle;
  }
}
