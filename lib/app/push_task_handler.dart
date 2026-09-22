import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../data/database/app_database.dart';
import '../data/repositories/account_watcher.dart';
import '../data/repositories/new_mail_notifier.dart';
import '../data/services/imap_service.dart';
import '../data/services/notification_service.dart';
import '../data/services/secure_store.dart';
import 'push_protocol.dart';

/// Ön plan servisinin içinde çalışan görev — uygulama kapalıyken bile Gelen
/// Kutusu'nu dinleyip yeni iletiyi geldiği anda bildirir.
///
/// AYRI BİR ISOLATE'TE çalışır: ana isolate'in bellekteki durumuna erişemez,
/// bağımlılıklarını kendi kurar (bkz. `background_sync.dart`'taki aynı kalıp).
/// Ana isolate ile konuşma yalnızca `PushProtocol` mesajlarıyla olur.
class PushTaskHandler extends TaskHandler {
  AppDatabase? _database;
  FlutterSecureStore? _secureStore;
  NewMailNotifier? _notifier;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;

  final Map<int, _Watched> _watched = {};

  /// Kullanıcının o an baktığı Gelen Kutusu (ana isolate bildirir).
  int? _uiInboxId;

  bool _reconciling = false;
  bool _reconcileAgain = false;
  bool _destroyed = false;

  /// Servis kapanırken izleyicilerin durması için tanınan süre — Android
  /// `onDestroy`'dan sonra süreci beklemeden öldürebilir.
  static const Duration _shutdownBudget = Duration(seconds: 4);

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final database = _database = AppDatabase();
    _secureStore = FlutterSecureStore();
    _notifier = NewMailNotifier(
      database: database,
      notifications: NotificationService(),
    );

    // Ağ geri gelince ölü bağlantılar hemen fark edilip yenilensin; aksi
    // hâlde bir sonraki IDLE turuna (dakikalar) kadar beklenirdi.
    _connectivity = Connectivity().onConnectivityChanged.listen((results) {
      if (results.every((r) => r == ConnectivityResult.none)) return;
      for (final entry in _watched.values) {
        entry.watcher.nudge();
      }
    });

    await _reconcile();

    // Ana isolate'ten güncel arayüz durumunu iste (bkz. `PushProtocol.hello`).
    FlutterForegroundTask.sendDataToMain(
      PushProtocol.message(PushProtocol.hello),
    );
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Kullanılmıyor: olay tabanlı çalışır (bkz. `PushService.initialize`).
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _destroyed = true;
    await _connectivity?.cancel();
    _connectivity = null;

    await Future.wait([
      for (final id in _watched.keys.toList())
        _stopWatching(id).timeout(_shutdownBudget, onTimeout: () {}),
    ]);

    await _database?.close();
  }

  @override
  void onReceiveData(Object data) {
    if (data is! Map) return;
    switch (data[PushProtocol.typeKey]) {
      case PushProtocol.ui:
        final inboxId = data[PushProtocol.inboxIdKey];
        _uiInboxId = inboxId is int ? inboxId : null;
      case PushProtocol.accounts:
        unawaited(_reconcile());
    }
  }

  // ------------------------------------------------------------ izleyiciler

  /// Cihazdaki hesaplarla çalışan izleyicileri eşler: yenisi başlar, silinen
  /// durur, kimlik hatasıyla durmuş olan (yeniden giriş yapılmış olabilir)
  /// yeniden denenir.
  Future<void> _reconcile() async {
    if (_reconciling) {
      _reconcileAgain = true;
      return;
    }
    _reconciling = true;
    try {
      do {
        _reconcileAgain = false;
        await _syncWatchers();
      } while (_reconcileAgain && !_destroyed);
    } finally {
      _reconciling = false;
    }
  }

  Future<void> _syncWatchers() async {
    final database = _database;
    if (database == null || _destroyed) return;

    final accounts = await database.allAccounts();
    final wanted = {for (final account in accounts) account.id};

    for (final id in _watched.keys.toList()) {
      if (!wanted.contains(id)) await _stopWatching(id);
    }
    for (final account in accounts) {
      _watched
          .putIfAbsent(account.id, () => _createWatched(account.id))
          .watcher
          .start();
    }
  }

  _Watched _createWatched(int accountId) {
    final imap = EnoughMailImapService();
    final watcher = AccountWatcher(
      accountId: accountId,
      database: _database!,
      imapService: imap,
      secureStore: _secureStore!,
      onSynced: _onSynced,
    );
    return _Watched(watcher, imap);
  }

  Future<void> _stopWatching(int accountId) async {
    final entry = _watched.remove(accountId);
    if (entry == null) return;
    await entry.watcher.stop();
    await entry.imap.dispose();
  }

  // --------------------------------------------------------------- sonuçlar

  Future<void> _onSynced(WatchedSync sync) async {
    final notifier = _notifier;
    if (notifier == null) return;
    final outcome = sync.outcome;

    if (outcome.newMessageIds.isNotEmpty && !outcome.initialDownload) {
      final viewing = await _isViewingInbox(sync.inboxId);
      await notifier.notifyNew(
        accountId: sync.accountId,
        outcome: outcome,
        suppressMailboxId: viewing ? sync.inboxId : null,
      );
    }

    // Başka bir cihazdan okunan/silinen iletilerin bildirimini kaldır.
    if (outcome.changedCount > 0 || outcome.deletedCount > 0) {
      await notifier.dismissHandled();
    }

    if (outcome.hasChanges) {
      FlutterForegroundTask.sendDataToMain(
        PushProtocol.message(PushProtocol.dbChanged),
      );
    }
  }

  /// Kullanıcı şu an bu Gelen Kutusu'nun listesine bakıyor mu?
  ///
  /// Ana isolate'in bildirdiği `_uiInboxId` tek başına yetmez: uygulama
  /// kullanıcı bir Gelen Kutusu'ndayken kaydırılıp kapatılırsa servis eski
  /// değeri sonsuza dek taşır ve o kutunun bildirimleri hiç çıkmazdı.
  /// Uygulamanın gerçekten ön planda olduğu ayrıca doğrulanır.
  Future<bool> _isViewingInbox(int inboxId) async {
    if (_uiInboxId != inboxId) return false;
    try {
      return await FlutterForegroundTask.isAppOnForeground;
    } on Object catch (_) {
      // Doğrulanamıyorsa bildirim göster: fazladan bildirim, kaçırılan
      // bildirimden iyidir.
      return false;
    }
  }
}

class _Watched {
  const _Watched(this.watcher, this.imap);

  final AccountWatcher watcher;
  final EnoughMailImapService imap;
}
