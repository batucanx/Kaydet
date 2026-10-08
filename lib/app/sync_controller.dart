import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/result.dart';
import '../data/database/app_database.dart';
import '../domain/models/mail_models.dart';
import '../data/repositories/sync_engine.dart';
import '../data/services/notification_service.dart';
import 'providers.dart';
import 'push_service.dart';
import 'push_stubs.dart';

/// Eşitleme durumu — arayüzdeki göstergeleri besler.
class SyncState {
  const SyncState({
    this.isSyncing = false,
    this.isLoadingMore = false,
    this.isOffline = false,
    this.lastError,
    this.lastSyncAt,
    this.hasMore = true,
    this.unreachableAccounts = const {},
  });

  final bool isSyncing;
  final bool isLoadingMore;
  final bool isOffline;
  final AppFailure? lastError;
  final DateTime? lastSyncAt;
  final bool hasMore;

  /// Sunucusuna kalıcı olarak ulaşılamayan hesaplar (bkz.
  /// `SyncController._noteConnectionFailure`). Değer, o hesabın son başarılı
  /// eşitleme zamanıdır (hiç olmadıysa `null`).
  final Map<int, DateTime?> unreachableAccounts;

  SyncState copyWith({
    bool? isSyncing,
    bool? isLoadingMore,
    bool? isOffline,
    AppFailure? lastError,
    bool clearError = false,
    DateTime? lastSyncAt,
    bool? hasMore,
    Map<int, DateTime?>? unreachableAccounts,
  }) => SyncState(
    isSyncing: isSyncing ?? this.isSyncing,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    isOffline: isOffline ?? this.isOffline,
    lastError: clearError ? null : (lastError ?? this.lastError),
    lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    hasMore: hasMore ?? this.hasMore,
    unreachableAccounts: unreachableAccounts ?? this.unreachableAccounts,
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
  Timer? _settingsRefresh;
  StreamSubscription<int?>? _remotePushes;
  Timer? _pushDebounce;

  /// Bir tur sürerken uzak push geldi: tur bitince hemen yeniden eşitlenir.
  bool _pushSyncPending = false;

  /// Eşitleme sürerken gelen sunucu olayı: tur bitince yeniden eşitlenir.
  bool _serverChangePending = false;
  DateTime? _lastFolderSync;
  bool _foldersSyncing = false;
  bool _folderSyncPending = false;
  bool _prefetchingBodies = false;
  bool _running = false;

  /// Tüm Hesaplar görünümünde TÜM hesapların son eşitlenme zamanı. Arka plan
  /// yoklaması yalnızca etkin hesabı eşitler; diğer hesaplar için bu süre
  /// dolunca bir tam tur yapılır (bkz. [_syncUnified]).
  DateTime? _lastUnifiedFullSync;
  static const Duration _unifiedFullSyncGap = Duration(minutes: 2);

  /// Bu ana kadar gelen sunucu olayları yok sayılır (bkz. [_onServerChange]).
  DateTime _quietUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// Kendi komutlarımızın (SELECT/FETCH/…) yanıtları da sunucu olayı üretebilir.
  /// Tur bittikten hemen sonra ulaşan gecikmiş olay bu kadar süre yok
  /// sayılır; aksi hâlde eşitleme kendi olaylarıyla sonsuza dek kendini
  /// tetikler.
  static const Duration _eventQuietPeriod = Duration(seconds: 1);
  bool _bootstrapped = false;
  bool _paused = false;
  bool _disposed = false;

  /// Klasör listesi bu süreden sık yenilenmez (ön plana dönüş, çekip yenileme).
  static const Duration _folderMinGap = Duration(seconds: 5);

  /// IDLE mailbox listesini kapsamaz; açık uygulamada dış klasör
  /// değişikliklerini en geç bu aralıkta yakalarız.
  static const Duration _folderPollInterval = Duration(seconds: 15);

  /// IDLE'ın kaçırdığı/bağlantı kopması sırasında gelen mesaj değişiklikleri
  /// için açık klasörün emniyet eşitlemesi.
  static const Duration _mailPollInterval = Duration(seconds: 25);

  /// Ayar belgesinin (etiket/imza) "değişti mi?" yoklaması: tek bir `STATUS`; belge
  /// ancak değiştiyse indirilir. Web'de yapılan değişiklik telefona bu sürede iner.
  static const Duration _settingsPollInterval = Duration(seconds: 8);

  @override
  SyncState build() {
    _disposed = false;
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
        _resetReachability();
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
        // Eski hesabın hatası yeni hesabın ekranında görünmez. Provider
        // değişikliği dinleyici içinde yapılamaz (bkz. yukarıdaki not).
        scheduleMicrotask(() {
          if (!ref.mounted || ref.read(accountIdProvider) != next) return;
          state = state.copyWith(clearError: true);
        });
        scheduleMicrotask(bootstrap);
      }
    });

    final accountId = ref.read(accountIdProvider);
    if (accountId != null) scheduleMicrotask(bootstrap);

    return const SyncState();
  }

  /// Tüm zamanlayıcı ve dinleyicileri kapatır.
  void _stopWatching() {
    _disposed = true;
    _idleRefresh?.cancel();
    _idleRefresh = null;
    _mailRefresh?.cancel();
    _mailRefresh = null;
    _folderRefresh?.cancel();
    _folderRefresh = null;
    _settingsRefresh?.cancel();
    _settingsRefresh = null;
    _serverChanges?.cancel();
    _serverChanges = null;
    _serverChangeDebounce?.cancel();
    _serverChangeDebounce = null;
    _connectivity?.cancel();
    _connectivity = null;
    _offlineConfirm?.cancel();
    _offlineConfirm = null;
    _remotePushes?.cancel();
    _remotePushes = null;
    _pushDebounce?.cancel();
    _pushDebounce = null;
    _pushSyncPending = false;
    _serverChangePending = false;
  }

  /// İlk kurulum: klasörleri çek, gelen kutusunu eşitle, dinlemeye başla.
  Future<void> bootstrap() async {
    if (_bootstrapped) return;
    final accountId = ref.read(accountIdProvider);
    if (accountId == null) return;
    _bootstrapped = true;
    _paused = false;
    // Son hesaptan çıkıp yeniden giriş yapılınca (bkz. `_stopWatching`)
    // zamanlayıcılar ve IDLE yeniden kurulabilsin.
    _disposed = false;

    _watchConnectivity();
    // İlk eşitleme sürerken (ya da çevrimdışı takılırsa) gelen push'lar
    // kaçmasın diye dinleyici eşitlemeden ÖNCE kurulur.
    _watchRemotePushes();
    // Bildirimlerden kalan ileti özetleri, eşitleme beklenmeden listeye düşer.
    _fireAndForget(ref.read(pushStubsProvider.notifier).refresh());
    await syncAll();
    _lastFolderSync = DateTime.now();
    _startFolderPolling();
    _startMailPolling();
    _startSettingsPolling();
    _watchServerChanges();
  }

  /// iOS'ta uygulama ön plandayken gelen uzak push (yeni ileti) anında
  /// eşitlemeyi tetikler; IDLE/yoklamanın yakalamasını beklenmez.
  void _watchRemotePushes() {
    _remotePushes?.cancel();
    _remotePushes = NotificationService.remotePushes.listen(_onRemotePush);
  }

  void _onRemotePush(int? accountId) {
    final active = ref.read(accountIdProvider);
    if (active == null || _disposed) return;
    // Başka hesabın iletisi: tek bağlantı etkin hesaba ait, o hesap
    // seçilince zaten eşitlenir (bkz. `bootstrap`).
    if (accountId != null && accountId != active) return;
    // Ön plandaki bir push iOS'ta hem `willPresent` hem
    // `didReceiveRemoteNotification` üzerinden gelir; art arda gelenler tek
    // eşitlemeye indirilir.
    _pushDebounce?.cancel();
    _pushDebounce = Timer(const Duration(milliseconds: 250), () {
      if (_disposed || _paused) return;
      if (_running || _foldersSyncing) {
        _pushSyncPending = true;
        return;
      }
      _fireAndForget(_syncForRemotePush());
    });
  }

  Future<void> _syncForRemotePush() async {
    final mailbox = ref.read(currentMailboxProvider);
    if (mailbox != null && mailbox.specialUse == SpecialUse.inbox) {
      await syncCurrentFolder();
    } else {
      await syncAll();
    }
  }

  /// Bağlantı kesildi bilgisi bu süre boyunca doğrulanmadan çevrimdışı
  /// sayılmaz: hesap değişimi/ağ el değiştirmesi (Wi‑Fi↔mobil, VPN) sırasında
  /// platform bir an "bağlantı yok" bildirir, oysa internet kopmamıştır.
  static const Duration _offlineConfirmDelay = Duration(seconds: 8);
  Timer? _offlineConfirm;

  static bool _isNone(List<ConnectivityResult> results) =>
      results.every((r) => r == ConnectivityResult.none);

  void _applyConnectivity(List<ConnectivityResult> results) {
    if (_disposed) return;
    if (!_isNone(results)) {
      _offlineConfirm?.cancel();
      _offlineConfirm = null;
      final wasOffline = state.isOffline;
      if (wasOffline) {
        state = state.copyWith(isOffline: false);
        scheduleMicrotask(syncAll);
      }
      return;
    }
    if (state.isOffline || _offlineConfirm != null) return;
    _offlineConfirm = Timer(_offlineConfirmDelay, () async {
      _offlineConfirm = null;
      try {
        final again = await Connectivity().checkConnectivity();
        if (_disposed) return;
        if (_isNone(again)) state = state.copyWith(isOffline: true);
      } on Object catch (_) {}
    });
  }

  void _watchConnectivity() {
    // Bağlantı durumu cihaz geneldir; hesap değişiminde aboneliği yeniden
    // kurmak platformdan sahte bir "bağlantı yok" olayı getirebilir.
    if (_connectivity != null) return;
    _connectivity = Connectivity().onConnectivityChanged.listen(
      _applyConnectivity,
    );
    // Akış yalnızca değişimleri bildirir; uygulama çevrimdışı açıldıysa
    // sunucu "ulaşılamıyor" sanılmasın diye ilk durum ayrıca okunur.
    unawaited(() async {
      try {
        _applyConnectivity(await Connectivity().checkConnectivity());
      } on Object catch (_) {}
    }());
  }

  void _watchServerChanges() {
    _serverChanges?.cancel();
    _serverChanges = ref
        .read(mailConnectionProvider)
        .serverChanges
        .listen((_) => _onServerChange());
  }

  /// Sunucudan gelen "değişiklik var" olayı (IMAP IDLE bildirimi).
  ///
  /// FETCH/SELECT yanıtları da IMAP event stream'ine düşebilir. Bunlar kendi
  /// sync komutlarımızdan üretildiğinde yeni bir sync başlatmak döngüye yol
  /// açar (bkz. `AccountWatcher._syncing`'deki aynı koruma).
  /// Devam eden tur varsa olay yutulmaz; [_serverChangePending] bayrağıyla
  /// tur biter bitmez yürütülmek üzere sıraya alınır.
  void _onServerChange() {
    if (_disposed || _paused) return;
    if (_running || _foldersSyncing) {
      _serverChangePending = true;
      return;
    }
    _serverChangeDebounce?.cancel();
    final now = DateTime.now();
    final quietRemaining = _quietUntil.difference(now);
    final delay = quietRemaining > Duration.zero
        ? quietRemaining + const Duration(milliseconds: 350)
        : const Duration(milliseconds: 350);

    _serverChangeDebounce = Timer(delay, () {
      if (_disposed || _paused) return;
      if (_running || _foldersSyncing) {
        _serverChangePending = true;
        return;
      }
      _fireAndForget(syncCurrentFolder());
    });
  }

  /// [accountId] hâlâ etkin hesap mı? Hesap değişince eski hesabın geç biten
  /// eşitlemesi yeni hesabın durumunu (hata, son eşitleme) bozmamalı.
  bool _isCurrent(int accountId) => ref.read(accountIdProvider) == accountId;

  /// Eşitleme hatasını arayüze yansıtır.
  ///
  /// Yalnızca kullanıcının yapabileceği bir şey olan hatalar (şifre, TLS,
  /// kota) afişe çıkar. Ağ/zaman aşımı/sunucu geçici hataları gösterilmez:
  /// yerel veri olduğu gibi durur; mevcut periyodik yoklama ve bağlantı
  /// geri gelince yeniden eşitleme (bkz. `_watchConnectivity`) zaten yeniden
  /// dener. Etkin olmayan hesabın hatası hiçbir zaman gösterilmez.
  void _reportFailure(int accountId, AppFailure failure) {
    // Bağlantı hatası afişe doğrudan çıkmaz; ardışık/süreli olursa hesap
    // "ulaşılamıyor" işaretlenir. Etkin olmayan hesap için de izlenir (rozet).
    if (failure is ConnectionFailure) {
      _noteConnectionFailure(accountId);
      return;
    }
    if (!_isCurrent(accountId) || !failure.isActionable) return;
    state = state.copyWith(lastError: failure);
  }

  /// Bir hesabın ilk ardışık bağlantı hatası ve sayısı.
  final Map<int, ({DateTime since, int count})> _connectionFailures = {};

  /// Hesabın son başarılı eşitleme zamanı ("ulaşılamıyor" şeridi için).
  final Map<int, DateTime> _lastSuccess = {};

  /// Ulaşılamayan hesapta periyodik yoklama bu ana kadar atlanır.
  final Map<int, DateTime> _retryNotBefore = {};

  /// "Sunucu ulaşılamıyor" demek için gereken ardışık hata sayısı ve ilk
  /// hatadan beri geçmesi gereken süre. Tek seferlik kopmalar bildirilmez.
  static const int _unreachableMinFailures = 2;
  static const Duration _unreachableMinSpan = Duration(seconds: 60);
  static const Duration _retryBaseDelay = Duration(seconds: 30);
  static const Duration _retryMaxDelay = Duration(minutes: 15);

  void _noteConnectionFailure(int accountId) {
    // Cihaz çevrimdışıyken sunucuyu suçlamayız (bkz. çevrimdışı şeridi).
    if (state.isOffline) {
      _connectionFailures.remove(accountId);
      return;
    }
    final now = DateTime.now();
    final previous = _connectionFailures[accountId];
    final entry = (since: previous?.since ?? now, count: (previous?.count ?? 0) + 1);
    _connectionFailures[accountId] = entry;
    if (entry.count < _unreachableMinFailures ||
        now.difference(entry.since) < _unreachableMinSpan) {
      return;
    }

    // Üstel bekleme: 30 sn, 1 dk, 2 dk … en çok 15 dk.
    final exponent = (entry.count - _unreachableMinFailures).clamp(0, 5);
    final delay = _retryBaseDelay * (1 << exponent);
    _retryNotBefore[accountId] =
        now.add(delay > _retryMaxDelay ? _retryMaxDelay : delay);

    if (state.unreachableAccounts.containsKey(accountId)) return;
    state = state.copyWith(
      unreachableAccounts: {
        ...state.unreachableAccounts,
        accountId: _lastSuccess[accountId],
      },
    );
  }

  /// Sunucu yanıt verdi: sayaç sıfırlanır, şerit/rozet kaybolur.
  void _noteReachable(int accountId) {
    _lastSuccess[accountId] = DateTime.now();
    _connectionFailures.remove(accountId);
    _retryNotBefore.remove(accountId);
    if (!state.unreachableAccounts.containsKey(accountId)) return;
    state = state.copyWith(
      unreachableAccounts: {...state.unreachableAccounts}..remove(accountId),
    );
  }

  /// Ulaşılamayan hesapta otomatik yoklama bekleme süresinde mi? Kullanıcı
  /// eylemleri (yeniden dene, çekip yenile, öne gelme) bunu yok sayar.
  bool _backingOff(int accountId) {
    final until = _retryNotBefore[accountId];
    return until != null && DateTime.now().isBefore(until);
  }

  void _resetReachability() {
    _connectionFailures.clear();
    _lastSuccess.clear();
    _retryNotBefore.clear();
  }

  /// Tur sürerken hesap değiştiyse yeni hesabın eşitlemesi buradan başlar
  /// (`syncAll` tur sürerken gelen çağrıyı atlar). `true` dönerse çağıran
  /// eski hesabın IDLE'ını yeniden kurmaz.
  bool _handOffIfSwitched(int accountId) {
    if (_isCurrent(accountId) || ref.read(accountIdProvider) == null) {
      return false;
    }
    _fireAndForget(syncAll());
    return true;
  }

  void _markQuiet() {
    _quietUntil = DateTime.now().add(_eventQuietPeriod);
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
      if (!_isCurrent(accountId)) return;
      if (mailboxes is Err<List<MailboxRow>>) {
        _reportFailure(accountId, mailboxes.failure);
        return;
      }

      _noteReachable(accountId);
      final boxes = (mailboxes as Ok<List<MailboxRow>>).value;
      final inbox = boxes.where((m) => m.specialUse == SpecialUse.inbox);
      if (inbox.isEmpty) return;

      final outcome = await engine.syncMailbox(
        accountId: accountId,
        mailbox: inbox.first,
      );
      if (!_isCurrent(accountId)) return;
      if (outcome is Err<SyncOutcome>) {
        _reportFailure(accountId, outcome.failure);
        return;
      }

      state = state.copyWith(
        lastSyncAt: DateTime.now(),
        hasMore: inbox.first.hasMoreOnServer,
        clearError: true,
      );
      _fireAndForget(ref.read(pushStubsProvider.notifier).reconcile());

      // Kuyruktaki kullanıcı eylemleri ve giden kutusu.
      await ref.read(mailRepositoryProvider).processQueue(accountId);

      // Etiket ve imzalar web ile eşitlenir (en çok 45 sn'de bir; arka planda).
      _fireAndForget(ref.read(settingsSyncServiceProvider).sync(accountId));

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
      _markQuiet();
      state = state.copyWith(isSyncing: false);
      if (!_handOffIfSwitched(accountId)) {
        await _restartIdle();
        _drainPendingFolderSync();
      }
    }
  }

  /// Yalnızca görüntülenen klasörü eşitler (aşağı çekerek yenileme).
  ///
  /// Tüm Hesaplar görünümünde [allAccounts] `true` ise (kullanıcı eylemi:
  /// klasör seçme, aşağı çekme) her hesabın ilgili klasörü eşitlenir; arka
  /// plan yoklaması ve IDLE tetikleri yalnızca etkin hesabı eşitler (bkz.
  /// [_syncUnified]).
  Future<void> syncCurrentFolder({bool allAccounts = false}) async {
    final accountId = ref.read(accountIdProvider);
    final unifiedUse = ref.read(selectedFolderProvider)?.unifiedUse;
    if (accountId == null) return;
    if (_running || _foldersSyncing) {
      // Sürmekte olan tur BAŞKA bir klasör içindir (ör. yeni hesabın ilk
      // Gelen Kutusu indirmesi). Çağrı sessizce düşseydi kullanıcının seçtiği
      // klasör, çekip yenilenene kadar hiç eşitlenmezdi; tur bitince
      // `_drainPendingFolderSync` bunu yeniden çalıştırır.
      _serverChangePending = true;
      return;
    }
    if (unifiedUse != null) {
      await _syncUnified(unifiedUse, allAccounts: allAccounts);
      return;
    }
    final mailbox = ref.read(currentMailboxProvider);
    // Klasör, hesap geçişi sırasında henüz eski hesabınki olabilir.
    if (mailbox != null && mailbox.accountId != accountId) return;

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
      if (!_isCurrent(accountId)) return;
      if (outcome is Err<SyncOutcome>) {
        _reportFailure(accountId, outcome.failure);
        return;
      }
      _noteReachable(accountId);
      state = state.copyWith(lastSyncAt: DateTime.now(), clearError: true);
      _fireAndForget(ref.read(pushStubsProvider.notifier).reconcile());
      await ref.read(mailRepositoryProvider).processQueue(accountId);
      _startBodyPrefetch(engine, accountId, mailbox);

      // Yerel önbellek tavanını aşan eski iletiler kademeli temizlenir
      // (bkz. `MailRepository.trimMailbox`) — arka planda, ekranı bloklamaz.
      _fireAndForget(ref.read(mailRepositoryProvider).trimMailbox(mailbox.id));

      _fireAndForget(_maybeNotify(mailbox, (outcome as Ok<SyncOutcome>).value));
    } finally {
      _running = false;
      _markQuiet();
      if (!_disposed) {
        state = state.copyWith(isSyncing: false);
        if (!_handOffIfSwitched(accountId)) {
          await _restartIdle();
          _drainPendingFolderSync();
        }
      }
    }
  }

  /// Tüm Hesaplar görünümünde [use] türündeki klasörleri eşitler.
  ///
  /// Tek IMAP bağlantısı hesaplar arasında sırayla kullanılır (bkz.
  /// `MailConnection.exclusive`); etkin hesap EN SONA bırakılır ki tur
  /// bittiğinde bağlantı (ve IDLE) yine etkin hesapta kalsın. Arka plan
  /// turları yalnızca etkin hesabı eşitler — diğer hesapları her yoklamada
  /// yeniden bağlamak pahalıdır; onlar için [_unifiedFullSyncGap] dolunca
  /// (ya da [allAccounts] ile) tam tur yapılır. Etkin olmayan hesabın hatası
  /// afişe çıkmaz (bkz. [_reportFailure]).
  Future<void> _syncUnified(SpecialUse use, {required bool allAccounts}) async {
    final activeId = ref.read(accountIdProvider);
    if (activeId == null) return;

    final now = DateTime.now();
    final last = _lastUnifiedFullSync;
    final full =
        allAccounts ||
        last == null ||
        now.difference(last) > _unifiedFullSyncGap;
    final accounts =
        ref.read(allAccountsProvider).value ?? const <AccountRow>[];
    final orderedIds = full
        ? [
            for (final a in accounts)
              if (a.id != activeId) a.id,
            activeId,
          ]
        : [activeId];

    _running = true;
    state = state.copyWith(isSyncing: true, clearError: true);
    try {
      final engine = ref.read(syncEngineProvider);
      final db = ref.read(databaseProvider);
      final repository = ref.read(mailRepositoryProvider);
      for (final id in orderedIds) {
        if (_disposed || !_isCurrent(activeId)) return;
        final box = await db.mailboxBySpecialUse(id, use);
        if (box == null) continue;
        final outcome = await engine.syncMailbox(accountId: id, mailbox: box);
        if (!_isCurrent(activeId)) return;
        if (outcome is Err<SyncOutcome>) {
          _reportFailure(id, outcome.failure);
          continue;
        }
        _noteReachable(id);
        await repository.processQueue(id);
        _fireAndForget(repository.trimMailbox(box.id));
        if (id == activeId) {
          _startBodyPrefetch(engine, id, box);
          _fireAndForget(_maybeNotify(box, (outcome as Ok<SyncOutcome>).value));
        }
      }
      if (full) _lastUnifiedFullSync = DateTime.now();
      state = state.copyWith(
        lastSyncAt: DateTime.now(),
        hasMore: ref
            .read(unifiedMailboxesProvider(use))
            .any((m) => m.hasMoreOnServer),
      );
    } finally {
      _running = false;
      _markQuiet();
      if (!_disposed) {
        state = state.copyWith(isSyncing: false);
        if (!_handOffIfSwitched(activeId)) {
          await _restartIdle();
          _drainPendingFolderSync();
        }
      }
    }
  }

  /// Tüm Hesaplar görünümünde "daha fazla yükle": önce yerel sınır büyür,
  /// yerel veri tükenmişse sunucuda daha eskisi olan her hesabın klasöründen
  /// bir sonraki sayfa indirilir.
  Future<void> _loadMoreUnified(SpecialUse use) async {
    state = state.copyWith(isLoadingMore: true);
    try {
      final db = ref.read(databaseProvider);
      final boxes = ref.read(unifiedMailboxesProvider(use));
      final shown = ref.read(messageListProvider).value?.length ?? 0;
      final limit = ref.read(pageLimitProvider);
      if (shown >= limit) {
        ref.read(pageLimitProvider.notifier).grow();
        var total = 0;
        for (final box in boxes) {
          total += await db.countMessages(box.id);
        }
        if (limit + PageLimitNotifier.step <= total) return;
      }

      final remote = boxes.where((m) => m.hasMoreOnServer).toList();
      if (remote.isEmpty) {
        state = state.copyWith(hasMore: false);
        return;
      }

      final engine = ref.read(syncEngineProvider);
      var loaded = 0;
      for (final box in remote) {
        await db.raiseRetentionLimit(box.id);
        final result = await engine.loadOlder(
          accountId: box.accountId,
          mailbox: box,
        );
        if (result is Ok<int>) {
          loaded += result.value;
        } else if (result is Err<int> &&
            result.failure is! UidValidityChangedFailure) {
          _reportFailure(box.accountId, result.failure);
        }
      }
      ref.read(pageLimitProvider.notifier).grow();
      state = state.copyWith(hasMore: loaded > 0);
    } finally {
      state = state.copyWith(isLoadingMore: false);
    }
  }

  /// Listenin sonuna gelindiğinde daha eski iletileri getirir.
  ///
  /// Önce yerel veritabanındaki gösterim sınırı büyütülür (anında sonuç),
  /// yerelde bitmişse sunucudan bir sonraki sayfa indirilir.
  Future<void> loadMore() async {
    if (state.isLoadingMore) return;
    final unifiedUse = ref.read(selectedFolderProvider)?.unifiedUse;
    if (unifiedUse != null) return _loadMoreUnified(unifiedUse);
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
        if (result.failure is UidValidityChangedFailure) {
          // Sunucu klasörü yeniden numaralamış: yerel UID'ler geçersiz, klasör
          // baştan eşitlenir. Kullanıcıya hata gösterilmez (bkz.
          // `UidValidityChangedFailure`).
          _fireAndForget(syncCurrentFolder());
          return;
        }
        _reportFailure(accountId, result.failure);
        return;
      }
      if (!_isCurrent(accountId)) return;
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
  /// Kutusu için. Kullanıcı o an listeye bakıyor olsa bile (ileti canlı
  /// düşse de) bildirim gösterilir.
  Future<void> _maybeNotify(MailboxRow mailbox, SyncOutcome outcome) async {
    if (mailbox.specialUse != SpecialUse.inbox) return;
    if (outcome.initialDownload || outcome.newMessageIds.isEmpty) return;
    if (!ref.read(settingsProvider).notificationsEnabled) return;

    final accountId = ref.read(accountIdProvider);
    if (accountId == null) return;

    // Bildirim yalnızca zarf alanlarını (gönderen/konu) ve varsa önizlemeyi
    // kullanır; gövde beklenmez — `prefetchBodies` arka planda sürer.
    await ref
        .read(newMailNotifierProvider)
        .notifyNew(accountId: accountId, outcome: outcome);
  }

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
    if (_disposed || _paused) return;

    final connection = ref.read(mailConnectionProvider);
    if (!connection.capabilities.supportsIdle) {
      return;
    }
    if (await _serviceWatches(ref.read(currentMailboxProvider))) return;
    if (_disposed || _paused) return;

    if (!connection.isConnected) {
      _serverChangePending = true;
      _drainPendingFolderSync();
      return;
    }

    final started = await connection.imap.startIdle();
    if (_disposed || _paused || started is Err<void>) return;
    _idleRefresh?.cancel();
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
    if (!force && _backingOff(accountId)) return;
    _foldersSyncing = true;
    try {
      final result = await ref
          .read(syncEngineProvider)
          .syncMailboxes(accountId);
      if (result is Ok<List<MailboxRow>>) {
        _lastFolderSync = DateTime.now();
        _noteReachable(accountId);
      } else if (result is Err<List<MailboxRow>>) {
        _reportFailure(accountId, result.failure);
      }
    } on Object catch (_) {
      // Beklenmeyen/geçici hata (ör. kilitli veritabanı): yerel veri
      // korunur, bir sonraki yoklamada yeniden denenir.
    } finally {
      _foldersSyncing = false;
      _markQuiet();
      if (!_disposed) {
        await _restartIdle();
        _drainPendingFolderSync();
      }
    }
  }

  void _drainPendingFolderSync() {
    if (_disposed || _running || _foldersSyncing || _paused) return;
    if (_serverChangePending) {
      _serverChangePending = false;
      scheduleMicrotask(() => _fireAndForget(syncCurrentFolder()));
      return;
    }
    if (_pushSyncPending) {
      _pushSyncPending = false;
      scheduleMicrotask(() => _fireAndForget(_syncForRemotePush()));
      return;
    }
    if (!_folderSyncPending) return;
    _folderSyncPending = false;
    scheduleMicrotask(() => _fireAndForget(syncFolders(force: true)));
  }

  void _startFolderPolling() {
    _folderRefresh?.cancel();
    if (_disposed || _paused) return;
    _folderRefresh = Timer.periodic(
      _folderPollInterval,
      (_) => _fireAndForget(syncFolders()),
    );
  }

  void _startSettingsPolling() {
    _settingsRefresh?.cancel();
    if (_disposed || _paused) return;
    _settingsRefresh = Timer.periodic(
      _settingsPollInterval,
      (_) => _fireAndForget(_syncSettings()),
    );
  }

  void _startMailPolling() {
    _mailRefresh?.cancel();
    if (_disposed || _paused) return;
    _mailRefresh = Timer.periodic(
      _mailPollInterval,
      (_) => _fireAndForget(_pollCurrentMailbox()),
    );
  }

  Future<void> _pollCurrentMailbox() async {
    // Anlık moddaki ön plan servisi Gelen Kutusu'nu zaten IDLE ile izler ve
    // Drift değişikliklerini ana isolate'e bildirir. Aynı kutuya ikinci bir
    // periyodik sync açıp gereksiz IMAP trafiği üretmeyelim.
    if (await _serviceWatches(ref.read(currentMailboxProvider))) return;

    // Sunucu ulaşılamıyorsa yoklama üstel bekleme süresince atlanır.
    final activeId = ref.read(accountIdProvider);
    if (activeId != null && _backingOff(activeId)) return;

    // Kullanıcı Gelen Kutusu dışındaki bir klasördeyse IDLE/yoklama yalnızca
    // o klasörü izler; Gelen Kutusu'na düşen yeni ileti push gelmezse
    // klasörden çıkılana kadar görünmezdi. Önce Gelen Kutusu eşitlenir, sonra
    // bağlantı (ve IDLE) görüntülenen klasöre geri döner.
    await _syncInboxWhileElsewhere();

    await syncCurrentFolder();
  }

  /// Görüntülenen klasör Gelen Kutusu değilse onu da eşitler ve yeni ileti
  /// bildirimini üretir. Tek IMAP bağlantısı sırayla kullanıldığı için
  /// çağıran, ardından görüntülenen klasörü yeniden eşitlemelidir (böylece
  /// seçili klasör ve IDLE geri döner).
  Future<void> _syncInboxWhileElsewhere() async {
    final accountId = ref.read(accountIdProvider);
    final current = ref.read(currentMailboxProvider);
    if (accountId == null || current == null) return;
    if (current.specialUse == SpecialUse.inbox) return;
    if (_disposed || _paused || _running || _foldersSyncing) return;

    final inbox = await ref
        .read(databaseProvider)
        .mailboxBySpecialUse(accountId, SpecialUse.inbox);
    if (inbox == null) return;
    // Android'de ön plan servisi Gelen Kutusu'nu zaten izliyor.
    if (await _serviceWatches(inbox)) return;
    if (_disposed || _paused || _running || _foldersSyncing) return;
    if (!_isCurrent(accountId)) return;

    _running = true;
    try {
      final outcome = await ref
          .read(syncEngineProvider)
          .syncMailbox(accountId: accountId, mailbox: inbox);
      if (!_isCurrent(accountId)) return;
      if (outcome is Ok<SyncOutcome>) {
        _noteReachable(accountId);
        _fireAndForget(_maybeNotify(inbox, outcome.value));
      } else if (outcome is Err<SyncOutcome> &&
          outcome.failure is ConnectionFailure) {
        _noteConnectionFailure(accountId);
      }
    } on Object catch (_) {
      // Geçici hata: bir sonraki yoklamada yeniden denenir.
    } finally {
      _running = false;
      _markQuiet();
    }
  }

  /// Ön plan servisi (bkz. `PushService`) [mailbox]'u (Gelen Kutusu) zaten
  /// IDLE ile izliyor mu? Servis TÜM hesapların Gelen Kutusu'nu dinler; o
  /// durumda arayüz aynı kutu için ikinci bir IDLE/yoklama açmaz — iki isolate
  /// aynı kutuyu aynı anda eşitleyip aynı iletiyi iki kez işlemesin, sunucunun
  /// eşzamanlı bağlantı sınırı boşuna tüketilmesin. Çekip yenileme, klasör
  /// değiştirme ve öne gelme gibi kullanıcı eylemleri bu korumadan etkilenmez.
  Future<bool> _serviceWatches(MailboxRow? mailbox) async {
    // Ön plan servisi (PushService) yalnızca Android'e özgüdür.
    // iOS'ta arayüz ön plandayken Gelen Kutusu'nu doğrudan kendisi (IMAP IDLE) izler.
    if (!Platform.isAndroid) return false;
    if (mailbox == null || mailbox.specialUse != SpecialUse.inbox) {
      return false;
    }
    try {
      return await PushService.isRunning;
    } on Object catch (_) {
      // Servis durumu okunamadıysa (ör. eklenti yok) arayüz kendi işini yapar.
      return false;
    }
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
        _markQuiet();
        if (!_disposed) {
          await _restartIdle();
          _drainPendingFolderSync();
        }
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
    _settingsRefresh?.cancel();
    _settingsRefresh = null;
    _serverChangeDebounce?.cancel();
    _serverChangeDebounce = null;
    _serverChangePending = false;
    await _serverChanges?.cancel();
    _serverChanges = null;
    await _remotePushes?.cancel();
    _remotePushes = null;
    _pushDebounce?.cancel();
    _pushDebounce = null;
    await ref.read(mailConnectionProvider).imap.stopIdle();
  }

  /// Uygulama öne geldiğinde yeniden eşitlenir.
  Future<void> resume() async {
    _paused = false;
    _fireAndForget(ref.read(pushStubsProvider.notifier).refresh());
    // Arka planda başka bir isolate (push/periyodik görev) veritabanına yazmış
    // olabilir; Drift akışları bunu kendiliğinden görmez, liste hemen tazelenir.
    final db = ref.read(databaseProvider);
    db.markTablesUpdated([db.messages, db.mailboxes]);
    _startFolderPolling();
    _startMailPolling();
    _startSettingsPolling();
    _watchServerChanges();
    _watchRemotePushes();
    // Arka planda ölmüş soket üzerinde SELECT 30 sn takılırdı; önce kısa bir
    // NOOP ile doğrulanır, ölüyse bir sonraki adım taze bağlanır.
    final activeId = ref.read(accountIdProvider);
    if (activeId != null) {
      await ref.read(mailConnectionProvider).revalidate(activeId);
    }
    await syncCurrentFolder();
    await syncFolders(force: true);
    _fireAndForget(_syncSettings(force: true));
  }

  /// Web'de değişen etiket/imzalar için ayar belgesini yoklar. Önce tek bir `STATUS`
  /// (seçili klasöre dokunmaz); belge değiştiyse tam tur çalışır, ardından görüntülenen
  /// klasör geri seçilir. Ayar klasörü IDLE ile izlenmediği için gecikmeyi bu yoklama sınırlar.
  Future<void> _syncSettings({bool force = false}) async {
    final accountId = ref.read(accountIdProvider);
    if (accountId == null ||
        _disposed ||
        _paused ||
        _running ||
        _foldersSyncing) {
      return;
    }
    if (!force && _backingOff(accountId)) return;
    final service = ref.read(settingsSyncServiceProvider);
    if (!force && !await service.hasRemoteChange(accountId)) {
      // STATUS komutu IDLE'ı bitirmiş olabilir.
      _markQuiet();
      if (!_disposed) await _restartIdle();
      return;
    }
    await service.sync(accountId, force: true);
    // Tam tur ayar klasörünü seçti: görüntülenen klasör ve IDLE geri gelsin.
    if (!_disposed && !_paused) await syncCurrentFolder();
  }

  void clearError() => state = state.copyWith(clearError: true);
}

final syncControllerProvider = NotifierProvider<SyncController, SyncState>(
  SyncController.new,
);
