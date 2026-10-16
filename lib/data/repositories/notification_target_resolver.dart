import 'dart:async';

import 'package:drift/drift.dart' show TableUpdateQuery;

import '../../core/mail_log.dart';
import '../../core/result.dart';
import '../../domain/models/mail_models.dart';
import '../../domain/use_cases/threading.dart';
import '../database/app_database.dart';

/// Tek bir iletiyi sunucudan UID'siyle getirip yerele yazan işlev (bkz.
/// `SyncEngine.fetchMessageByUid`). Dönüş: yerel satır kimliği; ileti
/// sunucuda yoksa `Ok(null)`.
typedef TargetFetcher =
    Future<Result<int?>> Function({
      required int accountId,
      required MailboxRow mailbox,
      required int uid,
      int? expectedUidValidity,
    });

/// Hedef iletinin nereden çözüldüğü.
enum TargetSource {
  /// Zaten yerel (Drift) veritabanındaydı — ağ beklenmedi.
  local,

  /// Yalnızca bu ileti sunucudan getirildi — tam eşitleme beklenmedi.
  server,

  /// Sunucudan doğrudan alınamadı; sürmekte olan eşitleme getirdi.
  awaitedSync,
}

enum TargetFailure {
  /// Bildirimin hesabı bu cihazda yok (çıkış yapılmış).
  accountMissing,

  /// İleti sunucuda artık yok (silinmiş/taşınmış) ya da UID geçersiz.
  notFound,

  /// İleti şu an getirilemedi (çevrimdışı, sunucu yanıt vermiyor).
  unavailable,
}

/// [NotificationTargetResolver.resolve] sonucu.
class TargetResolution {
  const TargetResolution.found(this.message, this.source) : failure = null;
  const TargetResolution.failed(TargetFailure this.failure)
    : message = null,
      source = null;

  final MessageRow? message;
  final TargetSource? source;
  final TargetFailure? failure;

  bool get isFound => message != null;
}

/// Bir bildirimin işaret ettiği iletiyi, TÜM Gelen Kutusu'nu eşitlemeden
/// bulur.
///
/// Sıra (her adım bir öncekinin başarısızlığında denenir):
/// 1. **Yerel** — Drift'te UID (UIDVALIDITY tutarlıysa) ya da `Message-ID`
///    ile; ileti başka klasöre taşınmış olsa da bulunur.
/// 2. **Sunucu, tek ileti** — `SELECT` + `UID FETCH` ile yalnızca bu ileti
///    gelir ve yazılır. [fetchers] sırayla denenir: ilki genelde ayrı, kısa
///    ömürlü bir bağlantıdır (uzun eşitlemenin bağlantı kilidini beklemez);
///    sonuncusu ana bağlantıdır.
/// 3. **Eşitlemeyi bekle** — sunucuya ulaşılamadıysa, sürmekte olan eşitlemenin
///    iletiyi yazmasını Drift akışıyla (sabit gecikme DEĞİL) bekler.
class NotificationTargetResolver {
  NotificationTargetResolver({
    required AppDatabase database,
    required List<TargetFetcher> fetchers,
    this.fetchTimeout = const Duration(seconds: 25),
    this.syncWait = const Duration(seconds: 20),
  }) : _db = database,
       _fetchers = fetchers;

  final AppDatabase _db;
  final List<TargetFetcher> _fetchers;

  /// Tek bir [TargetFetcher] denemesinin üst sınırı.
  final Duration fetchTimeout;

  /// Eşitlemenin iletiyi getirmesi için son bekleme süresi.
  final Duration syncWait;

  /// Yerel bildirim: yük doğrudan yerel satır kimliğidir.
  Future<TargetResolution> resolveLocalRow(int messageRowId) async {
    MailLog.target('local lookup row=$messageRowId');
    final row = await _db.messageById(messageRowId);
    if (row == null) return const TargetResolution.failed(TargetFailure.notFound);
    MailLog.target('message resolved source=local row=${row.id}');
    return TargetResolution.found(row, TargetSource.local);
  }

  /// Uzak (APNs) bildirim: hesap + klasör + UID (+ UIDVALIDITY, Message-ID).
  Future<TargetResolution> resolve({
    required int accountId,
    required int uid,
    String? folderPath,
    int? uidValidity,
    String? messageIdHeader,
  }) async {
    final header = Threading.normalizeId(messageIdHeader);
    final mailbox = await _mailboxFor(accountId, folderPath);

    // 1 — yerel
    MailLog.target('local lookup uid=$uid mailbox=${mailbox?.id}');
    final local = await _lookupLocal(
      accountId: accountId,
      mailbox: mailbox,
      uid: uid,
      uidValidity: uidValidity,
      header: header,
    );
    if (local != null) {
      MailLog.target('message resolved source=local row=${local.id}');
      return TargetResolution.found(local, TargetSource.local);
    }

    // 2 — sunucudan yalnızca bu ileti
    var serverAnswered = false;
    if (mailbox != null) {
      for (final fetch in _fetchers) {
        MailLog.target('server lookup uid=$uid mailbox=${mailbox.id}');
        final result = await _tryFetch(
          fetch,
          accountId: accountId,
          mailbox: mailbox,
          uid: uid,
          uidValidity: uidValidity,
        );
        if (result == null) continue; // bağlantı sorunu: sıradaki yol
        serverAnswered = true;
        if (result == _absent) break; // sunucu "yok" dedi
        final row = await _db.messageById(result);
        if (row != null) {
          MailLog.target('message resolved source=server row=${row.id}');
          return TargetResolution.found(row, TargetSource.server);
        }
        break;
      }
    }

    // Sunucu "ileti yok" dediyse: taşınmış olabilir — Message-ID ile son bakış.
    if (serverAnswered) {
      final moved = header == null
          ? null
          : await _db.messageByMessageIdHeaderInAccount(accountId, header);
      if (moved != null) {
        MailLog.target('message resolved source=local(moved) row=${moved.id}');
        return TargetResolution.found(moved, TargetSource.local);
      }
      MailLog.target('message not found on server uid=$uid');
      return const TargetResolution.failed(TargetFailure.notFound);
    }

    // 3 — sunucuya ulaşılamadı: sürmekte olan eşitlemeyi bekle
    MailLog.target('server unreachable; waiting for sync up to $syncWait');
    final awaited = await _awaitFromSync(
      accountId: accountId,
      mailbox: mailbox,
      uid: uid,
      uidValidity: uidValidity,
      header: header,
    );
    if (awaited != null) {
      MailLog.target('message resolved source=awaitedSync row=${awaited.id}');
      return TargetResolution.found(awaited, TargetSource.awaitedSync);
    }
    return const TargetResolution.failed(TargetFailure.unavailable);
  }

  /// Sunucunun "bu UID yok" yanıtını bağlantı hatasından ayırır.
  static const int _absent = -1;

  Future<int?> _tryFetch(
    TargetFetcher fetch, {
    required int accountId,
    required MailboxRow mailbox,
    required int uid,
    int? uidValidity,
  }) async {
    try {
      final result = await fetch(
        accountId: accountId,
        mailbox: mailbox,
        uid: uid,
        expectedUidValidity: uidValidity,
      ).timeout(fetchTimeout);
      return result.fold<int?>(
        (id) => id ?? _absent,
        (failure) {
          MailLog.target('server lookup failed: ${failure.runtimeType}');
          return null;
        },
      );
    } on TimeoutException {
      MailLog.target('server lookup timed out after $fetchTimeout');
      return null;
    } on Object catch (error) {
      MailLog.target('server lookup error: ${error.runtimeType}');
      return null;
    }
  }

  Future<MailboxRow?> _mailboxFor(int accountId, String? folderPath) async {
    final path = folderPath?.trim();
    if (path != null && path.isNotEmpty && path.toUpperCase() != 'INBOX') {
      final byPath = await _db.mailboxByPath(accountId, path);
      if (byPath != null) return byPath;
    }
    return _db.mailboxBySpecialUse(accountId, SpecialUse.inbox);
  }

  /// UID, yalnızca klasörün UIDVALIDITY'si bildirimdekiyle tutarlıysa ve
  /// satırın `Message-ID`'si çelişmiyorsa güvenilir sayılır; aksi hâlde aynı
  /// UID başka bir iletiye ait olabilir ve YANLIŞ ileti açılırdı.
  Future<MessageRow?> _lookupLocal({
    required int accountId,
    required MailboxRow? mailbox,
    required int uid,
    required int? uidValidity,
    required String? header,
  }) async {
    if (mailbox != null && _uidTrusted(mailbox, uidValidity)) {
      final byUid = await _db.messageByUid(mailbox.id, uid);
      if (byUid != null) {
        final stored = byUid.messageIdHeader;
        if (header == null || stored == null || stored == header) return byUid;
        MailLog.target('uid match rejected: Message-ID differs');
      }
    }
    if (header != null) {
      return _db.messageByMessageIdHeaderInAccount(accountId, header);
    }
    return null;
  }

  static bool _uidTrusted(MailboxRow mailbox, int? uidValidity) {
    final known = mailbox.uidValidity;
    return uidValidity == null || known == null || known == uidValidity;
  }

  /// Sürmekte olan eşitleme iletiyi yazana dek [syncWait] boyunca bekler.
  ///
  /// `messages` tablosu her değiştiğinde hedef yeniden aranır; bekleme süresi
  /// TOPLAM üst sınırdır (tablo sık değişse de uzamaz).
  Future<MessageRow?> _awaitFromSync({
    required int accountId,
    required MailboxRow? mailbox,
    required int uid,
    required int? uidValidity,
    required String? header,
  }) async {
    final changes = StreamController<void>();
    void poke() {
      if (!changes.isClosed) changes.add(null);
    }

    final updates = _db
        .tableUpdates(TableUpdateQuery.onTable(_db.messages))
        .listen((_) => poke());
    final deadline = Timer(syncWait, () {
      if (!changes.isClosed) unawaited(changes.close());
    });
    poke(); // tablo bu arada değişmiş olabilir: hemen bir kez bak
    try {
      await for (final _ in changes.stream) {
        final row = await _lookupLocal(
          accountId: accountId,
          mailbox: mailbox,
          uid: uid,
          uidValidity: uidValidity,
          header: header,
        );
        if (row != null) return row;
      }
      return null;
    } finally {
      deadline.cancel();
      await updates.cancel();
      if (!changes.isClosed) unawaited(changes.close());
    }
  }
}
