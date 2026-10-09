// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart'
    show TestDefaultBinaryMessengerBinding, WidgetTester;
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// Testte gerçek zamanda çalışan ileti okuma ekranının (avatar önbelleği,
/// bağlantı durumu) dokunduğu eklenti kanallarını sahteler; aksi hâlde
/// `MissingPluginException` testi düşürür.
void mockPluginChannels() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => Directory.systemTemp.path,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('dev.fluttercommunity.plus/connectivity'),
    (call) async => <String>['wifi'],
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
    (call) async => null,
  );
}

/// Widget testlerinde gerçek bir WebView olmadığı için ileti okuma ekranı
/// (bkz. `WebViewPool`, `_HtmlWebView`) bu sahte platformla kurulur.
///
/// WebView'a yüklenen HTML [FakeWebViewPlatform.loadedHtml] içinde tutulur;
/// testler "gövde gösterilir" gibi beklentileri buna bakarak doğrular.
class FakeWebViewPlatform extends WebViewPlatform {
  /// `loadHtmlString` ile yüklenen belgeler, yükleme sırasıyla.
  final List<String> loadedHtml = [];

  /// Yüklenen son ileti belgesi (ısıtma belgesi sayılmaz).
  String get lastMessageHtml => loadedHtml.lastWhere(
    (html) => html != '<!DOCTYPE html><html><body></body></html>',
    orElse: () => '',
  );

  /// İleti belgesi WebView'a yüklenene kadar bekler. Belge `Isolate.run` ve
  /// asset yüklemesiyle hazırlanır; bunlar `testWidgets`in sahte saatinde
  /// ilerlemez, bu yüzden gerçek zamanda (`runAsync`) beklenir.
  Future<void> untilMessageLoaded(
    WidgetTester tester, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (lastMessageHtml.isEmpty && DateTime.now().isBefore(deadline)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
  }

  /// Testin başında kurar ve sahteyi döndürür.
  static FakeWebViewPlatform install() {
    final platform = FakeWebViewPlatform();
    WebViewPlatform.instance = platform;
    return platform;
  }

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => _FakeController(params, this);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _FakeNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _FakeWidget(params);
}

class _FakeController extends PlatformWebViewController {
  _FakeController(super.params, this._owner) : super.implementation();

  final FakeWebViewPlatform _owner;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> enableZoom(bool enabled) async {}

  @override
  Future<void> setVerticalScrollBarEnabled(bool enabled) async {}

  @override
  Future<void> setOverScrollMode(WebViewOverScrollMode mode) async {}

  @override
  Future<void> addJavaScriptChannel(
    JavaScriptChannelParams javaScriptChannelParams,
  ) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> setOnScrollPositionChange(
    void Function(ScrollPositionChange scrollPositionChange)?
    onScrollPositionChange,
  ) async {}

  @override
  Future<void> runJavaScript(String javaScript) async {}

  @override
  Future<void> scrollBy(int x, int y) async {}

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    _owner.loadedHtml.add(html);
  }
}

class _FakeNavigationDelegate extends PlatformNavigationDelegate {
  _FakeNavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {}

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {}

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {}

  @override
  Future<void> setOnProgress(ProgressCallback onProgress) async {}

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {}

  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async {}

  @override
  Future<void> setOnHttpAuthRequest(
    HttpAuthRequestCallback onHttpAuthRequest,
  ) async {}
}

class _FakeWidget extends PlatformWebViewWidget {
  _FakeWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
