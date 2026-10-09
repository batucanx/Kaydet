import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/services/notification_service.dart';
import '../domain/models/mail_models.dart';
import '../ui/core/navigation/kaydet_route.dart';
import '../ui/features/compose/compose_launcher.dart';
import '../ui/features/compose/compose_screen.dart' show ComposeMode;
import '../ui/features/mail_detail/mail_detail_screen.dart';
import 'navigation.dart';
import 'providers.dart';
import 'sync_controller.dart';

/// Bildirime dokunulunca Gelen Kutusu kökünü HEMEN gösterir, ardından ilgili
/// iletiyi açar; "Yanıtla"ya dokunulunca o iletinin yanıt ekranını açar.
///
/// Sıra her zaman aynıdır (profesyonel posta uygulamalarındaki gibi):
/// 1. gezinme yığını kök kabuğa sıfırlanır (açık ileti/ayar/sheet/yan menü
///    kapanır) ve Gelen Kutusu seçilir — yerel (Drift) veriden, ağ beklemeden;
/// 2. ileti yerelde varsa üstüne açılır; yoksa eşitleme ARKA PLANDA sürer ve
///    ileti gelince (kullanıcı bu arada başka yere gitmediyse) açılır.
/// Bildirim kaynaklı hiçbir adım IMAP/ağ sonucunu beklemeden gezintiyi
/// geciktirmez.
///
/// `NotificationService`'in arka plan işleyicisi (Arşivle/Sil) ayrı bir
/// izole'de çalışır ve buraya bağlanamaz (bkz. `background_sync.dart` →
/// `notificationBackgroundHandler`); bu sınıf yalnızca uygulamayı öne getiren
/// dokunuşları — gövde ve "Yanıtla" — uygulama canlıyken ve soğuk
/// başlangıçta ele alır.
class NotificationNavigator {
  NotificationNavigator._(this._ref) {
    _sub = NotificationService.taps.listen(_handle);
    _remoteSub = NotificationService.mailTaps.listen(
      (_) => unawaited(_handleRemoteTap()),
    );
  }

  final Ref _ref;
  late final StreamSubscription<NotificationTap> _sub;
  late final StreamSubscription<void> _remoteSub;

  /// Her yeni dokunuşta artar: önceki dokunuşun arka plandaki "ileti gelince
  /// aç" beklemesi, yenisi geldiğinde kendiliğinden vazgeçer.
  int _generation = 0;

  /// Aynı bildirimin iki kez işlenmesini önler: soğuk başlangıçta hem
  /// `appLaunchDetails` hem eklentinin dokunma geri çağrısı aynı dokunuşu
  /// bildirebilir.
  String? _lastKey;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _dedupeWindow = Duration(seconds: 3);

  bool _isDuplicate(String key) {
    final now = DateTime.now();
    if (key == _lastKey && now.difference(_lastAt) < _dedupeWindow) {
      return true;
    }
    _lastKey = key;
    _lastAt = now;
    return false;
  }

  void _dispose() {
    _sub.cancel();
    _remoteSub.cancel();
  }

  /// Uygulama bir bildirime dokunularak açıldıysa (soğuk başlangıç) aynı
  /// hedefe gider. İlk kare çizildikten sonra çağrılmalı.
  Future<void> handleColdStart() async {
    // iOS uzak (APNs) bildirimi: yük yerel eklentiye değil AppDelegate'e düşer.
    // Bu çağrı beklenmez; yerel bildirim kontrolünü geciktirmez.
    unawaited(_handleRemoteTap());
    final details = await _ref
        .read(notificationServiceProvider)
        .appLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return;
    final tap = NotificationService.tapFromResponse(
      details!.notificationResponse,
    );
    if (tap != null) await _handle(tap);
  }

  /// Soğuk açılışta ana kabuk (açılış animasyonu + oturum kontrolü) hazır
  /// olana dek bekler; giriş ekranında kalındıysa `false` döner.
  Future<bool> _awaitShell() async {
    if (appShellReady.value) return true;
    final ready = Completer<bool>();
    void listener() {
      if (appShellReady.value && !ready.isCompleted) ready.complete(true);
    }

    appShellReady.addListener(listener);
    try {
      return await ready.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () => false,
      );
    } finally {
      appShellReady.removeListener(listener);
    }
  }

  /// Yığını kök kabuğa sıfırlar ve Gelen Kutusu'nu seçer. Eşzamanlıdır ve
  /// yalnızca yerel durumla çalışır; ağ beklemez.
  ///
  /// - Açık ileti/ayar/yazma ekranı ve sheet'ler `popUntil` ile kapanır.
  /// - Yan menü kabuk rotasının YEREL geçmişinde yaşar, `popUntil` ona
  ///   dokunmaz; bu yüzden ayrıca kapatılır.
  /// - Seçim modu, sayfalama ve sekme sıfırlanır (bkz. `AppShell._popToInbox`).
  void resetToInboxRoot({int? mailboxId}) {
    rootNavigatorKey.currentState?.popUntil((route) => route.isFirst);
    final scaffold = shellScaffoldKey.currentState;
    if (scaffold != null && scaffold.isDrawerOpen) scaffold.closeDrawer();
    FocusManager.instance.primaryFocus?.unfocus();

    _ref.read(selectionProvider.notifier).clear();
    _ref.read(pageLimitProvider.notifier).reset();
    _ref.read(activeTabProvider.notifier).select(0);
    final folder = _ref.read(selectedFolderRawProvider.notifier);
    if (mailboxId != null) {
      folder.select(SelectedFolder.mailbox(mailboxId));
    } else if (_ref.read(isAllAccountsProvider)) {
      folder.select(const SelectedFolder.unified(SpecialUse.inbox));
    } else {
      folder.reset();
    }
  }

  /// Kullanıcı kök Gelen Kutusu'nda mı (üstünde başka rota yok, yan menü
  /// kapalı)? Arka plandan gelen ileti ancak o zaman otomatik açılır.
  bool _stillAtRoot() {
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null || navigator.canPop()) return false;
    return shellScaffoldKey.currentState?.isDrawerOpen != true;
  }

  /// iOS'ta uzak bildirime dokunulunca hesap + IMAP uid'sinden iletiyi bulur
  /// ve açar. Önce Gelen Kutusu kökü gösterilir; ileti henüz yerelde yoksa
  /// (push eşitlemeden önce geldi) eşitleme arka planda sürer ve ileti
  /// gelince açılır.
  Future<void> _handleRemoteTap() async {
    final target = await _ref
        .read(notificationServiceProvider)
        .takePendingMailOpen();
    if (target == null) return;
    if (_isDuplicate('remote:${target.accountId}:${target.uid}')) return;
    final generation = ++_generation;

    if (!await _awaitShell() || generation != _generation) return;

    final accountId = target.accountId ?? _ref.read(accountIdProvider);
    if (accountId == null) return;
    if (accountId != _ref.read(accountIdProvider)) {
      // Yerel bir yazma; eski hesabın bağlantısı arka planda kapatılır.
      await _ref.read(accountRepositoryProvider).switchAccount(accountId);
      if (generation != _generation) return;
    }

    final db = _ref.read(databaseProvider);
    final inbox = await db.mailboxBySpecialUse(accountId, SpecialUse.inbox);
    if (generation != _generation) return;
    resetToInboxRoot(mailboxId: inbox?.id);
    if (inbox == null) return;

    unawaited(_openWhenAvailable(generation, inbox.id, target.uid));
  }

  /// İleti yerelde varsa hemen, yoksa eşitleme arka planda çalışırken
  /// yoklayarak açar. Bu arada yeni bir dokunuş geldiyse ya da kullanıcı
  /// başka bir yere gittiyse vazgeçer.
  Future<void> _openWhenAvailable(
    int generation,
    int mailboxId,
    int uid,
  ) async {
    final db = _ref.read(databaseProvider);
    for (var attempt = 0; attempt < 8; attempt++) {
      if (generation != _generation) return;
      final message = await db.messageByUid(mailboxId, uid);
      if (message != null) {
        if (generation != _generation) return;
        await _pushOnInbox(
          NotificationTap(message.id, NotificationTapKind.open),
        );
        return;
      }
      if (attempt == 0 || attempt == 3) {
        // Sürmekte olan bir tur varsa kuyruğa alınır; bitince çalışır.
        unawaited(
          _ref.read(syncControllerProvider.notifier).syncCurrentFolder(),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
  }

  Future<void> _handle(NotificationTap tap) async {
    if (_isDuplicate('local:${tap.kind.name}:${tap.messageId}')) return;
    final generation = ++_generation;

    if (!await _awaitShell() || generation != _generation) return;

    final db = _ref.read(databaseProvider);
    final message = await db.messageById(tap.messageId);
    if (message == null || generation != _generation) return;

    if (message.accountId != _ref.read(accountIdProvider)) {
      await _ref
          .read(accountRepositoryProvider)
          .switchAccount(message.accountId);
      if (generation != _generation) return;
    }
    resetToInboxRoot(mailboxId: message.mailboxId);
    await _pushOnInbox(tap);
  }

  /// Kök Gelen Kutusu bir kare çizildikten SONRA hedef ekranı açar: kullanıcı
  /// önce normal Gelen Kutusu'nu görür, ileti/yanıt onun üstüne gelir.
  Future<void> _pushOnInbox(NotificationTap tap) async {
    await WidgetsBinding.instance.endOfFrame;
    if (!_stillAtRoot()) return;
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) return;

    switch (tap.kind) {
      case NotificationTapKind.open:
        unawaited(
          navigator.push<void>(
            KaydetRoute<void>(
              builder: (_) => MailDetailScreen(messageId: tap.messageId),
            ),
          ),
        );
      case NotificationTapKind.reply:
        final repository = _ref.read(mailRepositoryProvider);
        unawaited(
          openComposeFromNavigator(
            navigator,
            replyToId: tap.messageId,
            mode: ComposeMode.reply,
            repository: repository,
          ),
        );
    }
  }
}

final notificationNavigatorProvider = Provider<NotificationNavigator>((ref) {
  final navigator = NotificationNavigator._(ref);
  ref.onDispose(navigator._dispose);
  return navigator;
});
