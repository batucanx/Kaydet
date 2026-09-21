import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/services/app_settings.dart';
import '../domain/models/mail_models.dart';
import 'providers.dart';
import 'push_protocol.dart';
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

    ref.listen(
      settingsProvider.select((s) => (s.notificationsEnabled, s.syncFrequency)),
      (_, _) => unawaited(_reconcile()),
    );
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
    ref.listen(activeTabProvider, (_, _) => unawaited(_sendUiState()));
    ref.listen(currentMailboxProvider, (_, _) => unawaited(_sendUiState()));

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
    unawaited(_sendUiState());
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
    try {
      final accounts = ref.read(allAccountsProvider).value;
      if (accounts == null) return; // henüz yüklenmedi; akış gelince döner

      final settings = ref.read(settingsProvider);
      final wanted =
          settings.notificationsEnabled &&
          settings.syncFrequency == SyncFrequency.push &&
          accounts.isNotEmpty &&
          await ref.read(notificationServiceProvider).areEnabled();

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

  /// Kullanıcı şu an bir Gelen Kutusu'nun listesine bakıyorsa onun kimliğini
  /// servise bildirir; servis o kutuya düşen iletiler için bildirim çıkarmaz.
  Future<void> _sendUiState() async {
    final mailbox = ref.read(currentMailboxProvider);
    final int? inboxId =
        ref.read(activeTabProvider) == 0 &&
            mailbox?.specialUse == SpecialUse.inbox
        ? mailbox!.id
        : null;
    await PushService.send(
      PushProtocol.message(PushProtocol.ui, {PushProtocol.inboxIdKey: inboxId}),
    );
  }

  void _onServiceData(Object data) {
    if (data is! Map) return;
    switch (data[PushProtocol.typeKey]) {
      case PushProtocol.hello:
        unawaited(_sendUiState());
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
