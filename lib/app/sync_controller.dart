import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/result.dart';
import '../data/database/app_database.dart';
import '../domain/models/mail_models.dart';
import '../data/repositories/sync_engine.dart';
import 'providers.dart';
import 'push_service.dart';

/// Eşitleme durumu — arayüzdeki göstergeleri besler.
class SyncState {
  const SyncState({
    this.isSyncing = false,
    this.isLoadingMore = false,
    this.isOffline = false,
    this.lastError,
    this.lastSyncAt,
    this.hasMore = true,
  });

  final bool isSyncing;
  final bool isLoadingMore;
  final bool isOffline;
  final AppFailure? lastError;
  final DateTime? lastSyncAt;
  final bool hasMore;

  SyncState copyWith({
    bool? isSyncing,
    bool? isLoadingMore,
    bool? isOffline,
    AppFailure? lastError,
    bool clearError = false,
    DateTime? lastSyncAt,
    bool? hasMore,
  }) =>
      SyncState(
        isSyncing: isSyncing ?? this.isSyncing,
        isLoadingMore: isLoadingMore ?? this.isLoadingMore,
        isOffline: isOffline ?? this.isOffline,
        lastError: clearError ? null : (lastError ?? this.lastError),
        lastSyncAt: lastSyncAt ?? this.lastSyncAt,
        hasMore: hasMore ?? this.hasMore,
      );
}

/// Eşitlemeyi yöneten denetleyici.
///
/// Arayüz hiçbir zaman doğrudan IMAP çağırmaz; buradan geçer. Böylece
/// aynı anda iki eşitleme başlamaz ve hatalar tek yerde ele alınır.
class SyncController extends Notifier<SyncState> {
  Timer? _idleRefresh;
  StreamSubscription<void>? _serverChanges;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  bool _running = false;
  bool _bootstrapped = false;

  @override
  SyncState build() {
    ref.onDispose(_stopWatching);

    // Hesap hazır olduğunda ilk eşitleme kendiliğinden başlar.
    ref.listen(accountIdProvider, (previous, next) {
      if (next == null) {
        // Çıkış yapıldı: zamanlayıcılar ve dinleyiciler durur. Aksi hâlde
        // silinmiş hesap için eşitleme denenmeye devam eder ve bir sonraki
        // girişte eski hata afişi ekranda kalır.
        _stopWatching();
        _bootstrapped = false;
        // Bu dinleyici, duraklatılmış bir `Consumer` aboneliği devam ederken
        // (ör. üstü örtülen ekran yeniden görününce) widget ağacı KURULURKEN
        // tetiklenebilir; o aşamada bir sağlayıcıyı değiştirmek Riverpod'da
        // hatadır. Sıfırlama bir sonraki mikro göreve ertelenir.
        scheduleMicrotask(() {
          if (!ref.mounted || ref.read(accountIdProvider) != null) return;
          state = const SyncState();
        });
        return;
      }
      if (previous != next) {
        _bootstrapped = false;
        scheduleMicrotask(bootstrap);
      }
    });

    final accountId = ref.read(accountIdProvider);
    if (accountId != null) scheduleMicrotask(bootstrap);

    return const SyncState();
  }

  /// Tüm zamanlayıcı ve dinleyicileri kapatır.
  void _stopWatching() {
    _idleRefresh?.cancel();
    _idleRefresh = null;
    _serverChanges?.cancel();
    _serverChanges = null;
    _connectivity?.cancel();
    _connectivity = null;
  }

  /// İlk kurulum: klasörleri çek, gelen kutusunu eşitle, dinlemeye başla.
  Future<void> bootstrap() async {
    if (_bootstrapped) return;
    final accountId = ref.read(accountIdProvider);
    if (accountId == null) return;
    _bootstrapped = true;

    _watchConnectivity();
    await syncAll();
    _watchServerChanges();
  }

  void _watchConnectivity() {
    _connectivity?.cancel();
    _connectivity = Connectivity().onConnectivityChanged.listen((results) {
      final offline = results.every((r) => r == ConnectivityResult.none);
      state = state.copyWith(isOffline: offline);
      if (!offline) {
        scheduleMicrotask(syncAll);
      }
    });
  }

  void _watchServerChanges() {
    _serverChanges?.cancel();
    _serverChanges = ref.read(mailConnectionProvider).serverChanges.listen(
      (_) => scheduleMicrotask(syncCurrentFolder),
    );
  }

  /// Tüm klasörleri ve seçili klasörün içeriğini eşitler.
  Future<void> syncAll() async {
    final accountId = ref.read(accountIdProvider);
    if (accountId == null || _running) return;
    _running = true;
    state = state.copyWith(isSyncing: true, clearError: true);

    try {
      final engine = ref.read(syncEngineProvider);
      final mailboxes = await engine.syncMailboxes(accountId);
      if (mailboxes is Err<List<MailboxRow>>) {
        state = state.copyWith(lastError: mailboxes.failure);
        return;
      }

      final boxes = (mailboxes as Ok<List<MailboxRow>>).value;
      final inbox = boxes.where((m) => m.specialUse == SpecialUse.inbox);
      if (inbox.isEmpty) return;

      final outcome = await engine.syncMailbox(
        accountId: accountId,
        mailbox: inbox.first,
      );
      if (outcome is Err<SyncOutcome>) {
        state = state.copyWith(lastError: outcome.failure);
        return;
      }

      state = state.copyWith(
        lastSyncAt: DateTime.now(),
        hasMore: inbox.first.hasMoreOnServer,
        clearError: true,
      );

      // Kuyruktaki kullanıcı eylemleri ve giden kutusu.
      await ref.read(mailRepositoryProvider).processQueue(accountId);

      // Önizleme metinleri için gövdeleri arka planda indir.
      unawaited(engine.prefetchBodies(accountId: accountId, mailbox: inbox.first));

      // Yerel önbellek tavanını aşan eski iletiler kademeli temizlenir
      // (bkz. `MailRepository.trimMailbox`) — arka planda, ekranı bloklamaz.
      _fireAndForget(
        ref.read(mailRepositoryProvider).trimMailbox(inbox.first.id),
      );

      _fireAndForget(
        _maybeNotify(inbox.first, (outcome as Ok<SyncOutcome>).value),
      );
    } finally {
      _running = false;
      state = state.copyWith(isSyncing: false);
      await _restartIdle();
    }
  }

  /// Yalnızca görüntülenen klasörü eşitler (aşağı çekerek yenileme).
  Future<void> syncCurrentFolder() async {
    final accountId = ref.read(accountIdProvider);
    final mailbox = ref.read(currentMailboxProvider);
    if (accountId == null || _running) return;

    // Sanal "Sabitlenenler" görünümünün gerçek bir klasörü yoktur; orada
    // yenileme tüm klasörleri eşitler, aksi hâlde aşağı çekmek hiçbir şey
    // yapmaz ve kullanıcı uygulamanın donduğunu sanır.
    if (mailbox == null) {
      await syncAll();
      return;
    }

    _running = true;
    state = state.copyWith(isSyncing: true, clearError: true);
    try {
      final engine = ref.read(syncEngineProvider);
      final outcome = await engine.syncMailbox(
        accountId: accountId,
        mailbox: mailbox,
      );
      if (outcome is Err<SyncOutcome>) {
        state = state.copyWith(lastError: outcome.failure);
        return;
      }
      state = state.copyWith(lastSyncAt: DateTime.now(), clearError: true);
      await ref.read(mailRepositoryProvider).processQueue(accountId);
      unawaited(engine.prefetchBodies(accountId: accountId, mailbox: mailbox));

      // Yerel önbellek tavanını aşan eski iletiler kademeli temizlenir
      // (bkz. `MailRepository.trimMailbox`) — arka planda, ekranı bloklamaz.
      _fireAndForget(ref.read(mailRepositoryProvider).trimMailbox(mailbox.id));

      _fireAndForget(_maybeNotify(mailbox, (outcome as Ok<SyncOutcome>).value));
    } finally {
      _running = false;
      state = state.copyWith(isSyncing: false);
      await _restartIdle();
    }
  }

  /// Listenin sonuna gelindiğinde daha eski iletileri getirir.
  ///
  /// Önce yerel veritabanındaki gösterim sınırı büyütülür (anında sonuç),
  /// yerelde bitmişse sunucudan bir sonraki sayfa indirilir.
  Future<void> loadMore() async {
    if (state.isLoadingMore) return;
    final accountId = ref.read(accountIdProvider);
    final mailbox = ref.read(currentMailboxProvider);
    if (accountId == null || mailbox == null) return;

    // `isLoadingMore` en baştan, İLK `await`'ten ÖNCE açılır — yerel
    // önbellekten (aşağıdaki hızlı yol) karşılanan istekler de dahil.
    // Aksi hâlde bu bayrak yalnızca sunucudan sayfa çekilen yolda
    // açılıyordu: önbellekte zaten yeterince ileti varsa (genelde öyle,
    // saklama sınırı gösterilen sayfa sınırından yüksek tutulur) fonksiyon
    // "Yükleniyor…" hiç görünmeden anında dönüyordu — hem görsel geri
    // bildirim eksik kalıyor hem de üstteki koruma
    // (`if (state.isLoadingMore) return;`) bu bekleme sırasında devre dışı
    // kalıp art arda hızlı dokunuşların yarışa girmesine izin veriyordu.
    state = state.copyWith(isLoadingMore: true);
    try {
      final shown = ref.read(messageListProvider).value?.length ?? 0;
      final limit = ref.read(pageLimitProvider);
      if (shown >= limit) {
        ref.read(pageLimitProvider.notifier).grow();
        final total = await ref
            .read(databaseProvider)
            .countMessages(mailbox.id);
        if (limit + PageLimitNotifier.step <= total) return;
      }

      if (!mailbox.hasMoreOnServer) {
        state = state.copyWith(hasMore: false);
        return;
      }

      // Yerelde gösterilecek her şey tükendi, sunucudan daha eskisi
      // isteniyor — klasörün yerel tavanı da büyütülür; aksi hâlde
      // `trimMailbox` birazdan indirilecek bu eski iletileri bir sonraki
      // senkronda hemen geri silerdi (bkz. `RetentionPolicy`).
      await ref.read(databaseProvider).raiseRetentionLimit(mailbox.id);
      final result = await ref.read(syncEngineProvider).loadOlder(
            accountId: accountId,
            mailbox: mailbox,
          );
      if (result is Err<int>) {
        state = state.copyWith(lastError: result.failure);
        return;
      }
      ref.read(pageLimitProvider.notifier).grow();
      state = state.copyWith(hasMore: (result as Ok<int>).value > 0);
    } finally {
      state = state.copyWith(isLoadingMore: false);
    }
  }

  /// Sonucu beklenmeyen yardımcı işler: hata yakalanır, yakalanmamış asenkron
  /// hataya dönüşmez (bildirim eklentisi, dosya sistemi, kilitli veritabanı).
  void _fireAndForget(Future<void> work) {
    unawaited(work.catchError((Object _) {}));
  }

  /// Ön planda yeni ileti geldiğinde bildirim gösterir — yalnızca Gelen
  /// Kutusu'nda ve kullanıcı o an tam da o klasörün listesine bakmıyorsa
  /// (bkz. bellek: farklı klasördeyken/ekrandayken bildir kararı). Aksi
  /// hâlde ileti zaten canlı olarak listede görünür, bildirim gereksiz
  /// gürültü olur.
  Future<void> _maybeNotify(MailboxRow mailbox, SyncOutcome outcome) async {
    if (mailbox.specialUse != SpecialUse.inbox) return;
    if (outcome.initialDownload || outcome.newMessageIds.isEmpty) return;
    if (!ref.read(settingsProvider).notificationsEnabled) return;

    final viewingThisInbox = ref.read(activeTabProvider) == 0 &&
        ref.read(currentMailboxProvider)?.id == mailbox.id;
    if (viewingThisInbox) return;

    final accountId = ref.read(accountIdProvider);
    if (accountId == null) return;

    // Bildirim yalnızca zarf alanlarını (gönderen/konu) ve varsa önizlemeyi
    // kullanır; gövde beklenmez — `prefetchBodies` arka planda sürer.
    await ref
        .read(newMailNotifierProvider)
        .notifyNew(accountId: accountId, outcome: outcome);
  }

  /// Ön plan servisi (bkz. `PushService`) çalışıyor mu?
  Future<bool> _pushServiceRunning() async {
    try {
      return await PushService.isRunning;
    } on Object catch (_) {
      return false;
    }
  }

  /// Uygulama önplandayken IMAP IDLE ile anlık güncelleme alınır.
  ///
  /// RFC 2177 gereği IDLE en geç 29 dakikada bir yenilenmelidir.
  ///
  /// "Anlık" modda ön plan servisi TÜM hesapların Gelen Kutusu'nu zaten
  /// dinler; arayüz o kutu için ikinci bir IDLE açmaz — iki isolate aynı
  /// kutuyu aynı anda eşitleyip aynı iletiyi iki kez işlemesin. Servisin
  /// yazdıkları `PushController` aracılığıyla listeye yansır. Diğer klasörler
  /// (Giden, özel klasörler) servis tarafından izlenmez; oralarda IDLE sürer.
  Future<void> _restartIdle() async {
    _idleRefresh?.cancel();
    final viewingInbox =
        ref.read(currentMailboxProvider)?.specialUse == SpecialUse.inbox;
    if (viewingInbox && await _pushServiceRunning()) return;

    final connection = ref.read(mailConnectionProvider);
    if (!connection.isConnected || !connection.capabilities.supportsIdle) {
      return;
    }
    await connection.imap.startIdle();
    _idleRefresh = Timer(const Duration(minutes: 25), () async {
      await connection.imap.stopIdle();
      await _restartIdle();
    });
  }

  /// Uygulama arka plana geçtiğinde IDLE durdurulur.
  Future<void> pause() async {
    _idleRefresh?.cancel();
    _idleRefresh = null;
    await ref.read(mailConnectionProvider).imap.stopIdle();
  }

  /// Uygulama öne geldiğinde yeniden eşitlenir.
  Future<void> resume() async {
    await syncCurrentFolder();
  }

  void clearError() => state = state.copyWith(clearError: true);
}

final syncControllerProvider =
    NotifierProvider<SyncController, SyncState>(SyncController.new);
