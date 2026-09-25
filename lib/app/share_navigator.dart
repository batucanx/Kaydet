import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/services/share_intake_service.dart';
import '../domain/models/share_payload.dart';
import '../domain/use_cases/share_attachment_policy.dart';
import '../ui/core/widgets/kaydet_notice.dart';
import '../ui/features/compose/compose_launcher.dart';
import 'navigation.dart';
import 'providers.dart';

/// Sistem "Paylaş" menüsünden (Galeri, Dosyalar…) "Kaydet" seçilince Yeni İleti
/// ekranını dosyalar ekli olarak açar.
///
/// `NotificationNavigator`'ın kardeşidir ve aynı kalıbı izler: widget ağacı
/// dışından, kök [rootNavigatorKey] ile gezinir; yeni bir gezinme yığını ya da
/// ikinci bir yazma ekranı YOKTUR — [openComposeFromNavigator] çağrılır ve ekler
/// `ComposeScreen`in mevcut ek listesine girer.
///
/// **Yarış durumları nasıl önlenir**
/// - *Motor/dinleyici hazır değil (soğuk başlangıç):* native taraf paylaşımı
///   iletmez, diske yazar; burada dinleyici KURULDUKTAN SONRA çekilir (bkz.
///   [ShareIntakeService]).
/// - *Gezinme/oturum hazır değil:* teslim yalnızca `Navigator` ağaca girmiş ve
///   bir hesap yüklenmişse yapılır. Hazır değilse paylaşım TÜKETİLMEZ (`ack`
///   gönderilmez), diskte bekler; hesap/gezinme hazır olunca ya da uygulama
///   öne gelince yeniden denenir.
/// - *Çifte işleme:* teslimler tek bir kuyrukta sırayla çalışır; işlenen her
///   paylaşım kimliği [_handled]de tutulur ve native tarafta manifest silinerek
///   kalıcı olarak tüketilir. Aynı Intent'in Activity yeniden yaratılınca
///   tekrar gelmesi native tarafta ayrıca engellenir (bkz. `MainActivity.kt`).
class ShareNavigator with WidgetsBindingObserver {
  ShareNavigator._(Ref ref)
    : _ref = ref,
      _service = ref.read(shareIntakeServiceProvider) {
    // SIRA ÖNEMLİ: önce dinleyici, sonra çekme (bkz. `ShareIntakeService.listen`).
    _service.listen();
    _changesSub = _service.changes.listen((_) => unawaited(deliverPending()));
    WidgetsBinding.instance.addObserver(this);

    // Hesap durumu netleşince yeniden bakılır: hesap yüklendiyse bekleyen
    // paylaşım teslim edilir; hesap YOKSA (giriş ekranı) kullanıcıya nedeni
    // söylenir ve paylaşım giriş sonrasına kadar diskte bekler.
    _ref.listen(activeAccountProvider, (previous, next) {
      if (!next.isLoading && !next.hasError) unawaited(deliverPending());
    });
  }

  final Ref _ref;
  final ShareIntakeService _service;
  late final StreamSubscription<void> _changesSub;

  /// Teslimleri sıraya dizen zincirin ucu.
  Future<void> _chain = Future<void>.value();

  /// Bu süreçte işlenmiş paylaşım kimlikleri; ack'i başarısız olsa bile aynı
  /// paylaşım ikinci bir yazma ekranı açmaz.
  final Set<String> _handled = {};

  /// "Önce hesap ekleyin" bildirimi paylaşım başına yalnızca bir kez gösterilir.
  final Set<String> _noAccountNotified = {};

  void _dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _changesSub.cancel();
  }

  /// İlk kare çizildikten sonra çağrılır: uygulama bir paylaşımla (soğuk
  /// başlangıç) açıldıysa yazma ekranını açar, ardından eski dosyaları süpürür.
  Future<void> handleColdStart() async {
    await deliverPending();
    unawaited(_sweep());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Arka plandaki uygulama paylaşımla öne getirildiğinde native dürtme
    // gelmeyebilir (iOS'ta yoktur); öne gelmek her durumda bir kontrol sebebi.
    if (state == AppLifecycleState.resumed) unawaited(deliverPending());
  }

  /// iOS Share Extension ana uygulamayı `kaydetshare://open` ile uyandırır.
  ///
  /// Motor bu URL'i normalde rota olarak iletir; `WidgetsApp` de onu bilinmeyen
  /// bir rotaya `pushNamed` ile açmaya çalışırdı. Bu gözlemci `WidgetsApp`ten
  /// ÖNCE kurulur (bkz. `_Bootstrap`) ve şemayı kendisi tüketir: rota açılmaz,
  /// yalnızca bekleyen paylaşım teslim edilir. (`Info.plist`te
  /// `FlutterDeepLinkingEnabled` de kapalıdır; bu ikinci savunma hattıdır.)
  @override
  Future<bool> didPushRouteInformation(
    RouteInformation routeInformation,
  ) async {
    if (routeInformation.uri.scheme != ShareIntakeService.iosUrlScheme) {
      return false;
    }
    unawaited(deliverPending());
    return true;
  }

  /// Bekleyen paylaşımları sırayla teslim eder. Eşzamanlı çağrılar birbirini
  /// beklemeden çalışmaz; tamamlanan Future, bu çağrının teslimi bittiğinde
  /// çözülür.
  Future<void> deliverPending() {
    final run = _chain.then((_) => _deliverAll());
    _chain = run.catchError((Object error, StackTrace stack) {
      debugPrint('Paylaşım teslim edilemedi: $error\n$stack');
    });
    return _chain;
  }

  Future<void> _deliverAll() async {
    final payloads = await _service.takePending();
    if (payloads.isEmpty) return;

    final account = _ref.read(activeAccountProvider);
    // Hesaplar henüz yükleniyor: hesap gelince dinleyici yeniden dener.
    if (account.isLoading || account.hasError) return;

    if (account.value == null) {
      _notifyNoAccount(payloads);
      return;
    }

    for (final payload in payloads) {
      // Navigator ağaçta değilse (çok erken) sonraki tetikleyiciyi bekle.
      if (rootNavigatorKey.currentState == null) return;
      await _deliver(payload);
    }
  }

  Future<void> _deliver(SharePayload incoming) async {
    if (_handled.contains(incoming.id)) {
      // Aynı paylaşım tekrar gelmiş (önceki ack başarısız kalmış olabilir).
      await _service.acknowledge(incoming.id);
      return;
    }

    final payload = await _service.prepare(incoming);
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) return;

    _rememberHandled(payload.id);

    // Kullanılabilir hiçbir şey kalmadı: yazma ekranı açmanın anlamı yok.
    if (payload.files.isEmpty && !payload.hasText) {
      _showNotice(
        navigator,
        ShareAttachmentPolicy.describe(payload.issues) ??
            'Paylaşılan içerik alınamadı.',
      );
      await _service.discard(payload.id);
      return;
    }

    final opened = openComposeFromNavigator(
      navigator,
      repository: _ref.read(mailRepositoryProvider),
      attachmentPaths: [for (final file in payload.files) file.path],
      subject: payload.subject,
      body: payload.text,
    );
    unawaited(
      opened.catchError((Object error, StackTrace stack) {
        debugPrint('Yazma ekranı açılamadı: $error\n$stack');
      }),
    );

    // Ekran açıldı: paylaşım artık kullanıcının taslağı. Kalıcı olarak
    // tüketildi işaretlenir; bu noktadan sonra yeniden teslim EDİLMEZ.
    await _service.acknowledge(payload.id);

    final message = ShareAttachmentPolicy.describe(payload.issues);
    if (message != null) _showNotice(navigator, message);
  }

  void _rememberHandled(String id) {
    // Sınırsız büyümesin; kimlikler UUID, çakışma pratikte imkânsız.
    if (_handled.length >= 64) _handled.remove(_handled.first);
    _handled.add(id);
  }

  void _notifyNoAccount(List<SharePayload> payloads) {
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) return;
    final fresh = payloads.where((p) => _noAccountNotified.add(p.id));
    if (fresh.isEmpty) return;
    _showNotice(
      navigator,
      'Paylaşılan içeriği eklemek için önce bir hesapla giriş yapın.',
    );
  }

  void _showNotice(NavigatorState navigator, String message) {
    final overlay = navigator.overlay;
    if (overlay == null || !overlay.mounted) return;
    KaydetNotice.show(
      overlay,
      message: message,
      duration: const Duration(seconds: 5),
    );
  }

  /// Artık hiçbir taslağın eki olmayan eski paylaşım dosyalarını siler.
  Future<void> _sweep() async {
    try {
      final referenced = await _ref
          .read(databaseProvider)
          .outgoingAttachmentPaths();
      await _service.sweep(referencedPaths: referenced);
    } on Object catch (error) {
      debugPrint('Paylaşım dosyaları temizlenemedi: $error');
    }
  }
}

final shareNavigatorProvider = Provider<ShareNavigator>((ref) {
  final navigator = ShareNavigator._(ref);
  ref.onDispose(navigator._dispose);
  return navigator;
});
