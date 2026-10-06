import 'dart:async';

import '../../domain/models/mail_models.dart';
import '../database/app_database.dart';
import '../services/managesieve_service.dart';
import 'mail_connection.dart';

/// [SenderFilterSync.sync] sonucu.
enum SenderFilterSyncResult { applied, unchanged, unsupported, skipped, failed }

/// Posta sunucusundaki filtreyi (Sieve) hesabın engellenenler listesiyle aynı tutar; böylece ileti
/// HİÇBİR Kaydet istemcisi çalışmıyorken ve başka her posta uygulamasında da İstenmeyen'e ayrılır.
/// İstemcinin Gelen Kutusu taraması (bkz. `SyncEngine`) güvenlik ağı olarak kalır. Web sunucusundaki
/// `SenderFilterSync` ile aynı kurallar.
///
/// Sessiz çalışır: hiç kimsenin engellenmediği hesaba (zorlanmadıkça) bağlanılmaz, bu çalışmada
/// zaten uygulanmış liste yeniden uygulanmaz, filtrelenemeyen sunucu [unsupportedRetry] dolana
/// dek rahat bırakılır.
class SenderFilterSync {
  SenderFilterSync({
    required AppDatabase database,
    required MailConnection connection,
    required ManageSieveService service,
    DateTime Function()? now,
    this.unsupportedRetry = const Duration(hours: 1),
  }) : _db = database,
       _connection = connection,
       _service = service,
       _now = now ?? DateTime.now;

  final AppDatabase _db;
  final MailConnection _connection;
  final ManageSieveService _service;
  final DateTime Function() _now;
  final Duration unsupportedRetry;

  final Map<int, String> _applied = {};
  final Map<int, DateTime> _unsupportedUntil = {};
  final Map<int, Future<SenderFilterSyncResult>> _running = {};
  final Map<int, ({Timer timer, bool force})> _scheduled = {};

  /// Bir değişiklik oldu: yakında uygula (art arda değişiklikler tek turu paylaşır).
  void request(
    int accountId, {
    bool force = false,
    Duration delay = const Duration(milliseconds: 1500),
  }) {
    final pending = _scheduled.remove(accountId);
    pending?.timer.cancel();
    final mustForce = force || (pending?.force ?? false);
    final timer = Timer(delay, () {
      _scheduled.remove(accountId);
      unawaited(sync(accountId, force: mustForce));
    });
    _scheduled[accountId] = (timer: timer, force: mustForce);
  }

  void dispose() {
    for (final entry in _scheduled.values) {
      entry.timer.cancel();
    }
    _scheduled.clear();
  }

  /// Bir tur; aynı hesap için süren bir tur varsa ona katılır.
  Future<SenderFilterSyncResult> sync(int accountId, {bool force = false}) {
    final running = _running[accountId];
    if (running != null) return running;
    // Blok gövde şart: `() => _running.remove(...)` kaldırdığı Future'ı (yani `run`ın kendisini)
    // döndürür; `whenComplete` döndürülen Future'ı beklediğinden tur kendini bekleyip kilitlenir.
    final run = _syncNow(accountId, force).whenComplete(() {
      _running.remove(accountId);
    });
    _running[accountId] = run;
    return run;
  }

  Future<SenderFilterSyncResult> _syncNow(int accountId, bool force) async {
    final emails = (await _db.blockedEmails(accountId)).toList()..sort();
    if (emails.isEmpty && !force) return SenderFilterSyncResult.skipped;
    final until = _unsupportedUntil[accountId];
    if (!force && until != null && until.isAfter(_now())) {
      return SenderFilterSyncResult.skipped;
    }

    final junk = await _db.mailboxBySpecialUse(accountId, SpecialUse.junk);
    if (junk == null) return SenderFilterSyncResult.skipped; // ayrılacak klasör yok

    final signature = '${junk.path}\u0000${emails.join('\u0001')}';
    if (!force && _applied[accountId] == signature) {
      return SenderFilterSyncResult.skipped;
    }

    final config = await _connection.imapConfig(accountId);
    if (config == null) return SenderFilterSyncResult.failed;
    final credential = config.credential;
    if (credential is! PasswordCredential) return SenderFilterSyncResult.failed;

    try {
      final outcome = await _service.apply(
        host: config.host,
        username: config.username,
        password: credential.password,
        emails: emails,
        junkMailbox: junk.path,
      );
      switch (outcome) {
        case SenderFilterOutcome.unsupported:
          _unsupportedUntil[accountId] = _now().add(unsupportedRetry);
          return SenderFilterSyncResult.unsupported;
        case SenderFilterOutcome.applied:
        case SenderFilterOutcome.unchanged:
          _unsupportedUntil.remove(accountId);
          _applied[accountId] = signature;
          return outcome == SenderFilterOutcome.applied
              ? SenderFilterSyncResult.applied
              : SenderFilterSyncResult.unchanged;
      }
    } on Object {
      return SenderFilterSyncResult.failed; // sonraki istek yeniden dener; Gelen Kutusu taraması örter
    }
  }
}
