import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/result.dart';
import '../data/database/app_database.dart';
import '../domain/models/mail_models.dart';
import '../data/repositories/sync_engine.dart';
import 'providers.dart';

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
  }) => SyncState(
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
  Timer? _mailRefresh;
  StreamSubscription<void>? _serverChanges;
  Timer? _serverChangeDebounce;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  Timer? _folderRefresh;
  DateTime? _lastFolderSync;
  bool _foldersSyncing = false;
  bool _folderSyncPending = false;
  bool _prefetchingBodies = false;
  bool _running = false;
  bool _bootstrapped = false;
  bool _paused = false;

  /// Klasör listesi bu süreden sık yenilenmez (ön plana dönüş, çekip yenileme).
  static const Duration _folderMinGap = Duration(seconds: 5);

  /// IDLE mailbox listesini kapsamaz; açık uygulamada dış klasör
  /// değişikliklerini en geç bu aralıkta yakalarız.
  static const Duration _folderPollInterval = Duration(seconds: 15);

  /// IDLE'ın kaçırdığı/bağlantı kopması sırasında gelen mesaj değişiklikleri
  /// için açık klasörün emniyet eşitlemesi.
  static const Duration _mailPollInterval = Duration(seconds: 25);

  @override
  SyncState build() {
    ref.onDispose(_stopWatching);

    ref.listen(currentMailboxProvider, (previous, next) {
      if (previous?.id != next?.id && next != null) {
        scheduleMicrotask(syncCurrentFolder);
      }
    });

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
    _mailRefresh?.cancel();
    _mailRefresh = null;
    _folderRefresh?.cancel();
    _folderRefresh = null;
    _serverChanges?.cancel();
    _serverChanges = null;
    _serverChangeDebounce?.cancel();
    _serverChangeDebounce = null;
    _connectivity?.cancel();
    _connectivity = null;
  }

  /// İlk kurulum: klasörleri çek, gelen kutusunu eşitle, dinlemeye başla.
  Future<void> bootstrap() async {
    if (_bootstrapped) return;
    final accountId = ref.read(accountIdProvider);
    if (accountId == null) return;
    _bootstrapped = true;
    _paused = false;

    _watchConnectivity();
    await syncAll();
    _lastFolderSync = DateTime.now();
    _startFolderPolling();
    _startMailPolling();
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
    _serverChanges = ref.read(mailConnectionProvider).serverChanges.listen((_) {
      // FETCH/SELECT yanıtları da IMAP event stream'ine düşebilir. Bunlar
      // kendi sync komutlarımızdan üretildiğinde yeni bir sync başlatmak
      // döngüye yol açar; devam eden tur ve periyodik emniyet sync'i bu
      // aralıkta kaçabilecek gerçek değişiklikleri zaten yakalar.
      // Debounce art arda gelen olayları tek bir eşitlemeye indirger.
      _serverChangeDebounce?.cancel();
      _serverChangeDebounce = Timer(
        const Duration(milliseconds: 350),
        () => _fireAndForget(syncCurrentFolder()),
      );
    });
  }

  /// Tüm klasörleri ve seçili klasörün içeriğini eşitler.
  Future<void> syncAll() async {
    final accountId = ref.read(accountIdProvider);
    if (accountId == null) return;
    if (_running) {
      _folderSyncPending = true;
      return;
    }
    if (_foldersSyncing) {
      return;
    }
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
      _startBodyPrefetch(engine, accountId, inbox.first);

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
      _drainPendingFolderSync();
    }
  }

  /// Yalnızca görüntülenen klasörü eşitler (aşağı çekerek yenileme).
  Future<void> syncCurrentFolder() async {
    final accountId = ref.read(accountIdProvider);
    final mailbox = ref.read(currentMailboxProvider);
    if (accountId == null || _running || _foldersSyncing) {
      return;
    }

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
      _startBodyPrefetch(engine, accountId, mailbox);

      // Yerel önbellek tavanını aşan eski iletiler kademeli temizlenir
      // (bkz. `MailRepository.trimMailbox`) — arka planda, ekranı bloklamaz.
      _fireAndForget(ref.read(mailRepositoryProvider).trimMailbox(mailbox.id));

      _fireAndForget(_maybeNotify(mailbox, (outcome as Ok<SyncOutcome>).value));
    } finally {
      _running = false;
      state = state.copyWith(isSyncing: false);
      await _restartIdle();
      _drainPendingFolderSync();
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
      final result = await ref
          .read(syncEngineProvider)
          .loadOlder(accountId: accountId, mailbox: mailbox);
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

    final viewingThisInbox =
        ref.read(activeTabProvider) == 0 &&
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

  /// Uygulama önplandayken IMAP IDLE ile anlık güncelleme alınır.
  ///
  /// IDLE düzenli olarak yenilenir; 30 saniyelik açık klasör eşitlemesi de
  /// sessizce kopmuş bir sokette kaçan değişiklikler için emniyet ağıdır.
  ///
  /// "Anlık" modda ön plan servisi TÜM hesapların Gelen Kutusu'nu zaten
  /// dinler; arayüz o kutu için ikinci bir IDLE açmaz — iki isolate aynı
  /// kutuyu aynı anda eşitleyip aynı iletiyi iki kez işlemesin. Servisin
  /// yazdıkları `PushController` aracılığıyla listeye yansır. Diğer klasörler
  /// (Giden, özel klasörler) servis tarafından izlenmez; oralarda IDLE sürer.
  Future<void> _restartIdle() async {
    _idleRefresh?.cancel();
    if (_paused) return;

    final connection = ref.read(mailConnectionProvider);
    if (!connection.isConnected || !connection.capabilities.supportsIdle) {
      return;
    }
    final started = await connection.imap.startIdle();
    if (started is Err<void>) return;
    _idleRefresh = Timer(const Duration(minutes: 8), () {
      // Yeni bir SELECT/FETCH IDLE'ı bitirir; sync'in finally bloğu IDLE'ı
      // yeniden başlatır. Bu tur bağlantı sağlığını da doğrular.
      _fireAndForget(syncCurrentFolder());
    });
  }

  /// Yalnızca klasör listesini eşitler (web istemcisinde eklenen/silinen
  /// klasörler). IDLE klasör değişikliklerini bildirmediği için ayrıca
  /// yapılır. [force] kısa aralık sınırını yok sayar.
  Future<void> syncFolders({bool force = false}) async {
    final accountId = ref.read(accountIdProvider);
    if (accountId == null) return;
    if (_foldersSyncing || _running) {
      _folderSyncPending = true;
      return;
    }
    final last = _lastFolderSync;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < _folderMinGap) {
      return;
    }
    _foldersSyncing = true;
    try {
      final result = await ref
          .read(syncEngineProvider)
          .syncMailboxes(accountId);
      if (result is Ok<List<MailboxRow>>) {
        _lastFolderSync = DateTime.now();
      } else if (result is Err<List<MailboxRow>>) {
        state = state.copyWith(lastError: result.failure);
      }
    } on Object catch (error) {
      state = state.copyWith(
        lastError: StorageFailure(detail: error.toString()),
      );
    } finally {
      _foldersSyncing = false;
      // `listMailboxes()` aynı IMAP bağlantısını kullandığı için
      // EnoughMail'in `_guard` metodu sürmekte olan IDLE'ı bitirir. Yeniden
      // başlatılmazsa klasör polling'i IDLE'ı sessizce devre dışı bırakırdı.
      await _restartIdle();
      _drainPendingFolderSync();
    }
  }

  void _drainPendingFolderSync() {
    if (!_folderSyncPending || _running || _foldersSyncing || _paused) return;
    _folderSyncPending = false;
    scheduleMicrotask(() => _fireAndForget(syncFolders(force: true)));
  }

  void _startFolderPolling() {
    _folderRefresh?.cancel();
    _folderRefresh = Timer.periodic(
      _folderPollInterval,
      (_) => _fireAndForget(syncFolders()),
    );
  }

  void _startMailPolling() {
    _mailRefresh?.cancel();
    _mailRefresh = Timer.periodic(
      _mailPollInterval,
      (_) => _fireAndForget(_pollCurrentMailbox()),
    );
  }

  Future<void> _pollCurrentMailbox() async {
    // Anlık moddaki ön plan servisi Gelen Kutusu'nu zaten IDLE ile izler ve
    // Drift değişikliklerini ana isolate'e bildirir. Aynı kutuya ikinci bir
    // periyodik sync açıp gereksiz IMAP trafiği üretmeyelim.

    await syncCurrentFolder();
  }

  void _startBodyPrefetch(
    SyncEngine engine,
    int accountId,
    MailboxRow mailbox,
  ) {
    if (_prefetchingBodies) return;
    _prefetchingBodies = true;
    unawaited(() async {
      try {
        await engine.prefetchBodies(accountId: accountId, mailbox: mailbox);
      } on Object catch (_) {
        // Gövde/önizleme indirme hatası temel mailbox sync'ini bozmaz.
      } finally {
        _prefetchingBodies = false;
        await _restartIdle();
      }
    }());
  }

  /// Uygulama arka plana geçtiğinde IDLE durdurulur.
  Future<void> pause() async {
    _paused = true;
    _idleRefresh?.cancel();
    _idleRefresh = null;
    _mailRefresh?.cancel();
    _mailRefresh = null;
    _folderRefresh?.cancel();
    _folderRefresh = null;
    _serverChangeDebounce?.cancel();
    _serverChangeDebounce = null;
    await _serverChanges?.cancel();
    _serverChanges = null;
    await ref.read(mailConnectionProvider).imap.stopIdle();
  }

  /// Uygulama öne geldiğinde yeniden eşitlenir.
  Future<void> resume() async {
    _paused = false;
    _startFolderPolling();
    _startMailPolling();
    _watchServerChanges();
    await syncCurrentFolder();
    await syncFolders(force: true);
  }

  void clearError() => state = state.copyWith(clearError: true);
}

final syncControllerProvider = NotifierProvider<SyncController, SyncState>(
  SyncController.new,
);
