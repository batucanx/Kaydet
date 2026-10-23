import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/services/app_settings.dart';
import '../data/services/push_token_source.dart';
import 'providers.dart';
import 'push_protocol.dart';
import 'remote_push_controller.dart';
import 'push_service.dart';

/// Ana isolate'te ön plan servisini ayarlara göre açıp kapatır ve servisle
/// konuşur (bkz. `PushService`, `PushTaskHandler`).
///
/// Servis şu koşulların HEPSİ sağlanırken çalışır: bildirimler açık, kontrol
/// sıklığı "Anlık", en az bir hesap var ve sistem bildirim izni verilmiş.
/// Herhangi biri bozulunca durdurulur — kalıcı bildirim ve pil maliyeti
/// gereksiz yere taşınmasın.
class PushController extends Notifier<void> {
  bool _reconciling = false;
  bool _reconcileAgain = false;

  @override
  void build() {
    PushService.addListener(_onServiceData);
    final lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    ref.onDispose(() {
      PushService.removeListener(_onServiceData);
      lifecycle.dispose();
    });

    // iOS badge'in tek kaynağı tüm hesapların yerel unread toplamıdır.
    // Android'in çalışan bildirim / servis davranışı bundan etkilenmez.
    final unreadSubscription = ref
        .read(databaseProvider)
        .watchAllUnreadCount()
        .listen((count) {
          unawaited(
            ref.read(notificationServiceProvider).setAppBadgeCount(count),
          );
        });
    ref.onDispose(unreadSubscription.cancel);

    ref.listen(
      settingsProvider.select((s) => (s.notificationsEnabled, s.syncFrequency)),
      (_, _) => unawaited(_reconcile()),
    );
    // Sunucu push'u (FCM) çalışıyorsa ön plan servisi gereksizdir; çalışmıyorsa
    // yedek olarak devreye girer (bkz. `ServerPushState`).
    ref.listen(remotePushControllerProvider, (_, _) => unawaited(_reconcile()));
    ref.listen(allAccountsProvider, (previous, next) {
      unawaited(_reconcile());
      unawaited(PushService.send(PushProtocol.message(PushProtocol.accounts)));

      // Çıkış yapılan hesabın iletileri silinir; bildirimleri gölgede kalıp
      // dokunulduğunda hiçbir yere gitmesin.
      final before = previous?.value;
      final after = next.value;
      if (before != null && after != null) {
        final remaining = {for (final account in after) account.id};
        if (before.any((account) => !remaining.contains(account.id))) {
          _dismissHandledNotifications();
        }
      }
    });

    // Android: aktif hesabı native tarafa bildir. Başka hesabın FCM push'u
    // uygulama öndeyken bile arka plan işçisiyle eşitlenip bildirilir; ana
    // bağlantı yalnızca aktif hesabı eşitler. iOS'ta etkisizdir.
    if (Platform.isAndroid) {
      ref.listen(
        accountIdProvider,
        (_, next) => unawaited(AndroidPushChannel.instance.setActiveAccount(next)),
        fireImmediately: true,
      );
      final syncSubscription = AndroidPushChannel.instance.backgroundSyncs
          .listen((_) {
            final db = ref.read(databaseProvider);
            db.markTablesUpdated([db.messages, db.mailboxes]);
          });
      ref.onDispose(syncSubscription.cancel);
    }

    // İlk hesap hazır olduğunda (ya da izin soran sürüme geçen mevcut
    // kullanıcıda ilk açılışta) bildirim izni bir kez istenir.
    //
    // Mikro görev şart: `fireImmediately` geri çağrısı `build` sırasında
    // eşzamanlı çalışır, oysa izin akışı `settingsProvider`ı günceller —
    // başka bir sağlayıcıyı kendi `build`i içinde değiştirmek Riverpod'da
    // hatadır.
    ref.listen(accountIdProvider, (previous, next) {
      if (previous == null && next != null) {
        scheduleMicrotask(_askPermissionOnce);
      }
    }, fireImmediately: true);

    scheduleMicrotask(_reconcile);
  }

  Future<void> _askPermissionOnce() async {
    try {
      await ref
          .read(settingsProvider.notifier)
          .requestNotificationPermissionOnce();
    } on Object catch (_) {
      // İzin penceresi açılamadı — ayarlardaki anahtar yine de çalışır.
    }
    await _reconcile();
  }

  void _onLifecycle(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;

    // Servis yalnızca uygulama öndeyken başlatılabilir (Android 12+); sistem
    // servisi öldürmüşse en erken bu an yeniden kurulur.
    unawaited(_reconcile());
    // Başka yerde okunan iletilerin bildirimleri gölgede kalmasın.
    _dismissHandledNotifications();
  }

  void _dismissHandledNotifications() {
    unawaited(
      ref
          .read(newMailNotifierProvider)
          .dismissHandled()
          .catchError((Object _) {}),
    );
  }

  // ---------------------------------------------------------- servis durumu

  Future<void> _reconcile() async {
    if (_reconciling) {
      _reconcileAgain = true;
      return;
    }
    _reconciling = true;
    try {
      do {
        _reconcileAgain = false;
        await _applyDesiredState();
      } while (_reconcileAgain);
    } finally {
      _reconciling = false;
    }
  }

  Future<void> _applyDesiredState() async {
    // Ön plan servisi (PushService / flutter_foreground_task) yalnızca Android içindir.
    // iOS'ta anlık bildirim APNs ve foreground IMAP IDLE ile yönetilir.
    if (!Platform.isAndroid) return;

    try {
      final accounts = ref.read(allAccountsProvider).value;
      if (accounts == null) return; // henüz yüklenmedi; akış gelince döner

      final settings = ref.read(settingsProvider);
      // FCM (sunucu push'u) çalışırken ön plan servisi, kalıcı bildirim ve pil
      // maliyetiyle gereksizdir. Servis yalnızca FCM bu cihazda kullanılamıyorsa
      // (Play hizmetleri yok, backend yapılandırılmamış), kayıt başarısızsa ya da
      // sunucu bazı hesapları izleyemiyorsa (`degraded`: kimlik reddedildi,
      // ulaşılamıyor) yedek olarak çalışır. Servis TÜM hesapları cihazdan IDLE ile
      // izlediği için sunucunun kör kaldığı hesaplar da bildirimsiz kalmaz.
      final serverPush = ref.read(remotePushControllerProvider);
      final needsFallback =
          serverPush == ServerPushState.unavailable ||
          serverPush == ServerPushState.failing ||
          serverPush == ServerPushState.degraded;
      final wanted =
          settings.notificationsEnabled &&
          settings.syncFrequency == SyncFrequency.push &&
          accounts.isNotEmpty &&
          needsFallback &&
          await ref.read(notificationServiceProvider).areEnabled();

      // Açılışta (cihaz yeniden başlayınca) servisi başlatan sistemdir, uygulama
      // değil; servis gereksizse kendini kapatabilsin diye karar kalıcı yazılır.
      await PushService.rememberNeeded(wanted);

      final running = await PushService.isRunning;
      if (wanted && !running) {
        await PushService.start();
      } else if (!wanted && running) {
        await PushService.stop();
      }
    } on Object catch (_) {
      // Servis kurulamadıysa periyodik görev (WorkManager) yedek olarak
      // çalışmaya devam eder; kullanıcıya hata göstermeye gerek yok.
    }
  }

  // -------------------------------------------------------------- mesajlar

  void _onServiceData(Object data) {
    if (data is! Map) return;
    switch (data[PushProtocol.typeKey]) {
      case PushProtocol.dbChanged:
        // Drift akışları başka isolate'in yazdığını kendiliğinden görmez.
        final db = ref.read(databaseProvider);
        db.markTablesUpdated([db.messages, db.mailboxes]);
    }
  }
}

final pushControllerProvider = NotifierProvider<PushController, void>(
  PushController.new,
);
