import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/mail_log.dart';
import '../data/database/app_database.dart' show MessageRow;
import '../data/repositories/notification_target_resolver.dart';
import '../data/services/notification_service.dart';
import '../domain/models/mail_models.dart';
import '../ui/core/navigation/kaydet_route.dart';
import '../ui/core/widgets/kaydet_notice.dart';
import '../ui/features/compose/compose_launcher.dart';
import '../ui/features/compose/compose_screen.dart' show ComposeMode;
import '../ui/features/mail_detail/mail_detail_screen.dart';
import 'navigation.dart';
import 'notification_intent.dart';
import 'providers.dart';

/// Bildirime dokunulunca hedef iletiyi (ya da "Yanıtla" ise yanıt ekranını)
/// açar — Gelen Kutusu'nda bırakmaz.
///
/// Bildirim gezintisi, normal açılıştan (Splash → Gelen Kutusu) ayrı ve
/// ÖNCELİKLİ bir niyettir. Akış (soğuk, sıcak, arka plan, ön plan — hepsinde
/// aynı):
///
/// 1. **Yakala** — dokunuş anında [NotificationIntake], hedefi süreç ömürlü
///    [PendingNotificationIntents]'e yazar (`runApp`ten önce). Sağlayıcılar,
///    veritabanı ya da eşitleme bu bilgiyi kaybettiremez.
/// 2. **Tüket** — bu sınıf niyeti alır ve tüketilmiş işaretler (aynı bildirim
///    ikinci kez ekran açmaz).
/// 3. **Hazır ol** — oturum/veritabanı ve ana kabuk (splash bitti) beklenir;
///    sabit gecikme DEĞİL, gerçek hazır olma sinyalleri.
/// 4. **Çöz** — [NotificationTargetResolver]: yerelde varsa hemen; yoksa
///    yalnızca o ileti sunucudan getirilir. TÜM Gelen Kutusu'nun eşitlenmesi
///    beklenmez; tam eşitleme kendi yolunda arka planda sürer.
/// 5. **Aç** — gezinme yığını kök kabuğa sıfırlanır, iletinin klasörü seçilir,
///    ileti üstüne açılır. Çözüm bitmeden Gelen Kutusu seçimi/yığın
///    DEĞİŞTİRİLMEZ.
///
/// İleti çözülemezse sessizce Gelen Kutusu'nda bırakılmaz: nedeni söyleyen bir
/// bildirim gösterilir.
///
/// `NotificationService`'in arka plan işleyicisi (Arşivle/Sil) ayrı bir
/// izole'de çalışır ve buraya bağlanamaz (bkz. `background_sync.dart` →
/// `notificationBackgroundHandler`); bu sınıf yalnızca uygulamayı öne getiren
/// dokunuşları — gövde ve "Yanıtla" — ele alır.
class NotificationNavigator {
  NotificationNavigator._(this._ref, this._store) {
    _sub = _store.changes.listen((_) => _onCaptured());
    // Niyet, bu sınıf kurulmadan önce (ör. `main()` içinde) yakalanmış olabilir.
    scheduleMicrotask(() => unawaited(_drain()));
  }

  final Ref _ref;
  final PendingNotificationIntents _store;
  late final StreamSubscription<void> _sub;

  /// Her yeni niyette artar: önceki niyetin sürmekte olan açılışı yenisi
  /// geldiğinde (ya da kullanıcı vazgeçince) kendiliğinden bırakılır.
  int _generation = 0;
  bool _draining = false;
  bool _disposed = false;

  /// Üst sınır: açılış animasyonu/oturum kontrolü hiç bitmezse sonsuza dek
  /// beklenmez.
  static const Duration _shellTimeout = Duration(seconds: 30);

  void _dispose() {
    _disposed = true;
    _sub.cancel();
    notificationOpening.value = false;
  }

  void _onCaptured() {
    _generation++;
    unawaited(_drain());
  }

  /// Uygulama ilk karesini çizdikten sonra çağrılır: bekleyen bir niyet varsa
  /// işlenir. Dokunuşun kendisi `main()` içinde zaten yakalanmıştır.
  Future<void> handleColdStart() => _drain();

  /// Kullanıcı "açılıyor" katmanında vazgeçti.
  void cancelOpening() {
    _generation++;
    notificationOpening.value = false;
    MailLog.navigation('opening cancelled by user');
  }

  Future<void> _drain() async {
    if (_draining || _disposed) return;
    _draining = true;
    try {
      while (!_disposed) {
        final intent = _store.take();
        if (intent == null) break;
        await _open(intent, _generation);
      }
    } finally {
      _draining = false;
      if (_store.pending == null) notificationOpening.value = false;
    }
  }

  // ------------------------------------------------------------------ akış

  Future<void> _open(NotificationIntent intent, int generation) async {
    bool stale() => generation != _generation || _disposed;

    final cold = !appShellReady.value;
    MailLog.app(
      '${cold ? 'cold' : 'warm'} start, '
      'lifecycle=${WidgetsBinding.instance.lifecycleState?.name ?? 'unknown'}',
    );
    MailLog.notification('consumed ${intent.summary}');
    notificationOpening.value = true;
    try {
      // Oturum + veritabanı: ilk sorgu cevaplanınca ikisi de hazırdır.
      final account = await _ref.read(activeAccountProvider.future);
      if (stale()) return;
      MailLog.database('ready');
      if (account == null) {
        // Giriş ekranı: açılacak bir hesap yok.
        MailLog.auth('no signed-in account; notification target dropped');
        return;
      }
      MailLog.auth('ready account=${account.id}');

      if (!await _awaitShell()) return;
      if (stale()) return;

      final resolution = await _resolve(intent, activeAccountId: account.id);
      if (stale()) return;

      final message = resolution.message;
      if (message == null) {
        _reportFailure(resolution.failure ?? TargetFailure.unavailable);
        return;
      }

      if (message.accountId != _ref.read(accountIdProvider)) {
        // Yerel bir yazma; eski hesabın bağlantısı arka planda kapatılır.
        await _ref.read(accountRepositoryProvider).switchAccount(
          message.accountId,
        );
        if (stale()) return;
      }

      resetToInboxRoot(mailboxId: message.mailboxId);
      await WidgetsBinding.instance.endOfFrame;
      if (stale()) return;
      _push(intent, message);
    } on Object catch (error, stack) {
      MailLog.navigation('open failed: ${error.runtimeType}');
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'notification navigator',
        ),
      );
      if (!stale()) _reportFailure(TargetFailure.unavailable);
    } finally {
      if (generation == _generation) notificationOpening.value = false;
    }
  }

  Future<TargetResolution> _resolve(
    NotificationIntent intent, {
    required int activeAccountId,
  }) async {
    final resolver = _ref.read(notificationTargetResolverProvider);
    if (intent.isLocal) return resolver.resolveLocalRow(intent.messageRowId!);

    final accountId = intent.accountId ?? activeAccountId;
    if (await _ref.read(databaseProvider).accountById(accountId) == null) {
      MailLog.auth('notification account=$accountId is not on this device');
      return const TargetResolution.failed(TargetFailure.accountMissing);
    }
    if (accountId != _ref.read(accountIdProvider)) {
      // Bildirim başka bir hesaba ait: hedef çözülmeden doğru hesaba geçilir,
      // yanlış hesabın Gelen Kutusu'nda aranmaz.
      await _ref.read(accountRepositoryProvider).switchAccount(accountId);
    }
    return resolver.resolve(
      accountId: accountId,
      uid: intent.uid!,
      folderPath: intent.folderPath,
      uidValidity: intent.uidValidity,
      messageIdHeader: intent.messageIdHeader,
    );
  }

  /// Ana kabuk (splash bitti, oturum var) ekrana gelene dek bekler.
  Future<bool> _awaitShell() async {
    if (appShellReady.value) return true;
    final ready = Completer<bool>();
    void listener() {
      if (appShellReady.value && !ready.isCompleted) ready.complete(true);
    }

    appShellReady.addListener(listener);
    try {
      return await ready.future.timeout(
        _shellTimeout,
        onTimeout: () {
          MailLog.app('shell not ready after $_shellTimeout');
          return false;
        },
      );
    } finally {
      appShellReady.removeListener(listener);
    }
  }

  void _reportFailure(TargetFailure failure) {
    final message = switch (failure) {
      TargetFailure.accountMissing =>
        'Bu ileti için hesap bu cihazda bulunamadı.',
      TargetFailure.notFound => 'Bu ileti artık kullanılamıyor.',
      TargetFailure.unavailable =>
        'İleti şu an açılamadı. Bağlantınızı kontrol edip Gelen Kutusu\'ndan '
            'açabilirsiniz.',
    };
    MailLog.navigation('target unresolved: ${failure.name}');
    final overlay = rootNavigatorKey.currentState?.overlay;
    if (overlay == null) return;
    KaydetNotice.show(
      overlay,
      message: message,
      duration: const Duration(seconds: 5),
    );
  }

  // --------------------------------------------------------------- gezinme

  /// Yığını kök kabuğa sıfırlar ve [mailboxId] klasörünü seçer. Eşzamanlıdır
  /// ve yalnızca yerel durumla çalışır; ağ beklemez.
  ///
  /// - Açık ileti/ayar/yazma ekranı ve sheet'ler `popUntil` ile kapanır.
  /// - Yan menü kabuk rotasının YEREL geçmişinde yaşar, `popUntil` ona
  ///   dokunmaz; bu yüzden ayrıca kapatılır.
  /// - Seçim modu, sayfalama ve sekme sıfırlanır (bkz. `AppShell._popToInbox`).
  ///
  /// Yalnızca hedef ileti çözüldükten SONRA çağrılır; çözülemeyen bir
  /// bildirim kullanıcının mevcut ekranını bozmaz.
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

  void _push(NotificationIntent intent, MessageRow message) {
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) return;

    switch (intent.kind) {
      case NotificationTapKind.open:
        MailLog.navigation('opening message row=${message.id}');
        unawaited(
          navigator.push<void>(
            KaydetRoute<void>(
              builder: (_) => MailDetailScreen(messageId: message.id),
            ),
          ),
        );
      case NotificationTapKind.reply:
        MailLog.navigation('opening reply row=${message.id}');
        unawaited(
          openComposeFromNavigator(
            navigator,
            replyToId: message.id,
            mode: ComposeMode.reply,
            repository: _ref.read(mailRepositoryProvider),
          ),
        );
    }
  }
}

final notificationNavigatorProvider = Provider<NotificationNavigator>((ref) {
  final navigator = NotificationNavigator._(
    ref,
    ref.watch(pendingNotificationIntentsProvider),
  );
  ref.onDispose(navigator._dispose);
  return navigator;
});
