import 'dart:async';

import '../../core/result.dart';
import '../../domain/models/mail_models.dart';
import '../database/app_database.dart';
import '../services/imap_service.dart';
import '../services/secure_store.dart';
import 'mail_connection.dart';
import 'sync_engine.dart';

/// Bir eşitleme turunun sonucu — [AccountWatcher.onSynced] alır.
class WatchedSync {
  const WatchedSync({
    required this.accountId,
    required this.inboxId,
    required this.outcome,
  });

  final int accountId;
  final int inboxId;
  final SyncOutcome outcome;
}

/// Bir hesabın Gelen Kutusu'nu SÜREKLİ dinler: kendi IMAP bağlantısını açık
/// tutar, sunucu "yeni ileti" dediği anda eşitler ve sonucu bildirir.
///
/// Uygulamanın ana bağlantısı ([MailConnection]) tek hesapla sınırlıdır ve
/// arayüz için kuruludur. Anlık bildirim ise TÜM hesaplar için aynı anda
/// dinleme ister; bu yüzden her hesaba ayrı bağlantı açılır ve ön plan servisi
/// (`push_task_handler.dart`) içinde yaşar.
///
/// Döngü: bağlan → Gelen Kutusu'nu eşitle → IDLE'a gir → (sunucu değişikliği |
/// zaman aşımı | dürtme) ile uyan → tekrar eşitle. Bağlantı koparsa üstel geri
/// çekilmeyle yeniden bağlanır ve her bağlanışta eksik kalan iletileri
/// yakalar. Kimlik hatası kalıcıdır: izleyici durur (şifre değişmiş olabilir)
/// ve hesap yeniden giriş yapılana dek denenmez.
class AccountWatcher {
  AccountWatcher({
    required this.accountId,
    required AppDatabase database,
    required ImapService imapService,
    required SecureStore secureStore,
    required this.onSynced,
    this.onFoldersSynced,
  }) : _db = database,
       _imap = imapService {
    _connection = MailConnection(
      database: database,
      secureStore: secureStore,
      imapService: imapService,
      // Kendi canlılık denetimimiz var (bkz. `_idleCycle`).
      keepAlive: false,
    );
    _engine = SyncEngine(database: database, connection: _connection);
  }

  final int accountId;

  /// Her başarılı eşitlemeden sonra çağrılır. Hatası izleyiciyi durdurmaz.
  final Future<void> Function(WatchedSync sync) onSynced;

  /// Klasör listesi eşitlendiğinde çağrılır.
  final Future<void> Function(int accountId)? onFoldersSynced;

  final AppDatabase _db;
  final ImapService _imap;
  late final MailConnection _connection;
  late final SyncEngine _engine;

  /// IDLE'da en fazla bu kadar beklenir. RFC 2177 29 dakika der, ancak mobil
  /// operatörlerin NAT tabloları boşta TCP bağlantılarını çok daha erken
  /// düşürür; bu tur aynı zamanda ölü bağlantının fark edilme süresidir.
  static const Duration _idleCycle = Duration(minutes: 9);

  /// IDLE desteklemeyen sunucular için yoklama aralığı.
  static const Duration _pollInterval = Duration(minutes: 3);

  /// Sunucu olayları bu süre susmadan eşitleme başlatılmaz — art arda gelen
  /// birkaç olay tek eşitlemeye indirgenir.
  static const Duration _debounce = Duration(milliseconds: 700);

  /// Klasör listesi (web istemcisinde eklenen/silinen/yeniden adlandırılan
  /// klasörler) en sık bu aralıkla yenilenir. IDLE yalnızca Gelen Kutusu'nu
  /// izler; klasör değişikliklerini sunucu bildirmez.
  static const Duration _folderRefreshInterval = Duration(minutes: 2);

  /// Yeni iletilerin önizleme metni için gövde indirmeye ayrılan süre.
  /// Aşılırsa bildirim yalnızca konuyla gösterilir; gecikme yaşatılmaz.
  static const Duration _previewBudget = Duration(seconds: 6);

  /// Bir bağlantı bundan kısa yaşadıysa "sağlıklı" sayılmaz (bkz. `_run`).
  static const Duration _minHealthyLifetime = Duration(seconds: 30);

  static const List<Duration> _backoff = [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
  ];

  bool _running = false;
  DateTime? _lastFolderSync;
  Future<void>? _loop;
  Completer<void>? _wake;
  Timer? _debounceTimer;
  StreamSubscription<void>? _changes;

  /// Eşitleme sürerken gelen sunucu olayları yok sayılır: kendi
  /// komutlarımızın (SELECT/FETCH) yanıtları da olay üretebilir ve bunlara
  /// tepki vermek bitmeyen bir eşitleme döngüsü yaratırdı.
  bool _syncing = false;

  /// İzlemeyi başlatır. Zaten çalışıyorsa hiçbir şey yapmaz.
  void start() {
    if (_running) return;
    _running = true;
    _loop = _run();
  }

  /// İzlemeyi durdurur ve bağlantıyı kapatır.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _interrupt();
    await _loop;
    _loop = null;
  }

  /// Bekleyen uykuyu keser ve hemen eşitletir (ağ geri geldi, kullanıcı
  /// yeniledi). Ölü bir bağlantı bu eşitlemede hata verir ve yeniden bağlanılır.
  void nudge() => _interrupt();

  // ------------------------------------------------------------------ döngü

  Future<void> _run() async {
    var failures = 0;
    try {
      while (_running) {
        final startedAt = DateTime.now();
        var end = _SessionEnd.failed;
        try {
          end = await _session();
        } on Object catch (_) {
          // Beklenmeyen hata (ayrıştırma, veritabanı kilidi) izleyiciyi
          // öldürmemeli: bağlantı yenilenip yeniden denenir.
        }
        if (!_running) break;

        // Bağlantı kopmuş olabilir ama `isLoggedIn` hâlâ `true` görünebilir;
        // `ensureConnected` o durumda yeniden bağlanmadan "hazır" derdi ve
        // aynı ölü soketle sonsuza kadar hata alırdık. Her oturum sonunda
        // bağlantı bilerek kapatılır.
        await _closeConnection();

        switch (end) {
          case _SessionEnd.authFailed:
            // Kalıcı: şifre/oturum geçersiz. Yeniden denemek hesabı
            // sunucuda kilitleyebilir.
            _running = false;
            return;
          case _SessionEnd.ended:
            // Uzun süre yaşamış bir bağlantının kopması normaldir; hemen
            // kopan bağlantı (kararsız sunucu, IDLE'ı reddeden proxy) ise
            // arızadır ve geri çekilmeyi büyütmelidir — yoksa sürekli
            // bağlanıp kopan bir döngü pil ve sunucu kotasını tüketir.
            final lived = DateTime.now().difference(startedAt);
            failures = lived < _minHealthyLifetime ? failures + 1 : 0;
          case _SessionEnd.failed:
            failures++;
        }

        final delay = _backoff[(failures - 1).clamp(0, _backoff.length - 1)];
        await _waitForWake(delay);
      }
    } finally {
      await _teardown();
    }
  }

  /// Tek bir bağlantı ömrü. Bağlantı kopunca ya da durdurulunca döner.
  Future<_SessionEnd> _session() async {
    final connected = await _connection.ensureConnected(accountId);
    if (connected is Err<void>) {
      return connected.failure is AuthFailure
          ? _SessionEnd.authFailed
          : _SessionEnd.failed;
    }

    final inboxId = await _resolveInboxId();
    if (inboxId == null) return _SessionEnd.failed;

    await _changes?.cancel();
    _changes = _imap.serverChanges.listen((_) {
      if (_syncing) return;
      _debounceTimer?.cancel();
      _debounceTimer = Timer(_debounce, _interrupt);
    });

    try {
      final supportsIdle = _connection.capabilities.supportsIdle;
      while (_running) {
        final synced = await _syncInbox(inboxId);
        if (synced == _SyncResult.authFailed) return _SessionEnd.authFailed;
        if (synced == _SyncResult.failed) return _SessionEnd.ended;
        if (!_running) break;
        await _refreshFolders();
        if (!_running) break;

        if (supportsIdle) {
          final started = await _imap.startIdle();
          if (started is Err<void>) return _SessionEnd.ended;
        }
        await _waitForWake(supportsIdle ? _idleCycle : _pollInterval);
      }
      return _SessionEnd.ended;
    } finally {
      _debounceTimer?.cancel();
      _debounceTimer = null;
      await _changes?.cancel();
      _changes = null;
    }
  }

  /// Klasör listesini eşitler; hata dinlemeyi kesmez (bir sonraki turda
  /// yeniden denenir). Bağlantı sağlığını Gelen Kutusu eşitlemesi belirler.
  Future<void> _refreshFolders() async {
    final last = _lastFolderSync;
    if (last != null &&
        DateTime.now().difference(last) < _folderRefreshInterval) {
      return;
    }
    try {
      final result = await _engine.syncMailboxes(accountId);
      if (result is Ok<List<MailboxRow>>) {
        _lastFolderSync = DateTime.now();
        await onFoldersSynced?.call(accountId);
      }
    } on Object catch (_) {}
  }

  Future<int?> _resolveInboxId() async {
    var inbox = await _db.mailboxBySpecialUse(accountId, SpecialUse.inbox);
    if (inbox == null) {
      final listed = await _engine.syncMailboxes(accountId);
      if (listed is Err<List<MailboxRow>>) return null;
      inbox = await _db.mailboxBySpecialUse(accountId, SpecialUse.inbox);
    }
    return inbox?.id;
  }

  Future<_SyncResult> _syncInbox(int inboxId) async {
    _syncing = true;
    try {
      // Her turda satır yeniden okunur: `syncMailbox` UIDVALIDITY'yi verilen
      // satırdaki değerle karşılaştırır, bayat bir satır her turda gereksiz
      // tam yeniden indirmeye yol açardı.
      final inbox = await _db.mailboxById(inboxId);
      if (inbox == null) return _SyncResult.failed;

      final result = await _engine.syncMailbox(
        accountId: accountId,
        mailbox: inbox,
      );
      if (result is Err<SyncOutcome>) {
        return result.failure is AuthFailure
            ? _SyncResult.authFailed
            : _SyncResult.failed;
      }
      final outcome = (result as Ok<SyncOutcome>).value;

      // Bildirim önizlemesi gövdeden gelir (bkz. `MailNotificationText`).
      if (!outcome.initialDownload && outcome.newMessageIds.isNotEmpty) {
        await _prefetchPreviews(inbox, outcome.newMessageIds.length);
      }

      try {
        await onSynced(
          WatchedSync(
            accountId: accountId,
            inboxId: inbox.id,
            outcome: outcome,
          ),
        );
      } on Object catch (_) {
        // Bildirim gösterilemedi diye dinleme kesilmez.
      }
      return _SyncResult.ok;
    } finally {
      _syncing = false;
    }
  }

  Future<void> _prefetchPreviews(MailboxRow inbox, int count) async {
    try {
      await _engine
          .prefetchBodies(
            accountId: accountId,
            mailbox: inbox,
            limit: count.clamp(1, 10),
          )
          .timeout(_previewBudget);
    } on Object catch (_) {
      // Önizleme yoksa bildirim yalnızca gönderen + konuyla çıkar.
    }
  }

  // ------------------------------------------------------------ bekleme

  /// [timeout] dolana ya da [_interrupt] çağrılana dek bekler. Hem IDLE
  /// turunu hem geri çekilme uykusunu kapsar; `stop()` ikisini de hemen keser.
  Future<void> _waitForWake(Duration timeout) async {
    final wake = Completer<void>();
    _wake = wake;
    final timer = Timer(timeout, _interrupt);
    await wake.future;
    timer.cancel();
    _wake = null;
  }

  void _interrupt() {
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  Future<void> _closeConnection() async {
    try {
      await _connection.disconnect();
    } on Object catch (_) {
      // Kapanış hatası önemsiz — soket zaten bırakılıyor.
    }
  }

  Future<void> _teardown() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    await _changes?.cancel();
    _changes = null;
    await _closeConnection();
  }
}

enum _SessionEnd { ended, failed, authFailed }

enum _SyncResult { ok, failed, authFailed }
