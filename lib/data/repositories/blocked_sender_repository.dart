import '../../domain/models/mail_models.dart';
import '../database/app_database.dart';
import 'mail_repository.dart';
import 'sender_filter_sync.dart';
import 'settings_sync_service.dart';

/// [BlockedSenderRepository.block] sonucu.
enum BlockOutcome {
  /// Adres engellendi.
  blocked,

  /// Adres zaten engelliydi; hiçbir şey değişmedi.
  alreadyBlocked,

  /// Geçerli bir e-posta adresi değil.
  invalidAddress,

  /// Hesabın kendi adresi: engellenemez (kendi gönderdiğiniz iletiler İstenmeyen'e düşerdi).
  ownAddress,
}

class BlockResult {
  const BlockResult(this.outcome, {this.row, this.handle});

  final BlockOutcome outcome;

  /// Engellenen (ya da zaten engelli olan) adresin satırı.
  final BlockedSenderRow? row;

  /// Gelen Kutusu'ndaki mevcut iletilerin İstenmeyen'e taşınmasının geri alma tutamağı
  /// (taşınacak ileti yoksa `null`).
  final MailActionHandle? handle;
}

/// Engellenen kullanıcılar (web istemcisindeki "Engellenenler" ile aynı kurallar).
///
/// Engellemek: adres listeye girer, Gelen Kutusu'ndaki iletileri İstenmeyen'e taşınır ve
/// bundan sonra gelenler de oraya gider (bkz. `SyncEngine`, SUNUCUDA taşır). Engeli kaldırmak:
/// adres listeden çıkar, İstenmeyen'deki iletileri Gelen Kutusu'na taşınır. Liste, ayar belgesi
/// üzerinden web ve diğer cihazlarla eşitlenir (bkz. `SettingsSyncService`).
class BlockedSenderRepository {
  BlockedSenderRepository({
    required AppDatabase database,
    required MailRepository mail,
    SettingsSyncService? settingsSync,
    SenderFilterSync? senderFilter,
  }) : _db = database,
       _mail = mail,
       _settingsSync = settingsSync,
       _senderFilter = senderFilter;

  final AppDatabase _db;
  final MailRepository _mail;
  final SettingsSyncService? _settingsSync;

  /// Posta sunucusundaki filtre: engellenenin gelecekteki iletileri sunucuda kendiliğinden İstenmeyen'e ayrılır.
  final SenderFilterSync? _senderFilter;

  Future<BlockResult> block({
    required int accountId,
    required String email,
    String name = '',
  }) async {
    final address = email.trim().toLowerCase();
    if (!EmailAddress.isValidEmail(address)) {
      return const BlockResult(BlockOutcome.invalidAddress);
    }
    final account = await _db.accountById(accountId);
    if (account != null && account.email.trim().toLowerCase() == address) {
      return const BlockResult(BlockOutcome.ownAddress);
    }

    final inserted = await _db.insertBlockedSender(
      accountId: accountId,
      email: address,
      name: name,
    );
    if (!inserted.created) {
      return BlockResult(BlockOutcome.alreadyBlocked, row: inserted.row);
    }
    _settingsSync?.schedule(accountId);
    _senderFilter?.request(accountId, force: true);

    final handle = await _moveMessages(
      accountId: accountId,
      from: SpecialUse.inbox,
      to: SpecialUse.junk,
      email: address,
    );
    return BlockResult(BlockOutcome.blocked, row: inserted.row, handle: handle);
  }

  /// Engeli kaldırır; `false`: böyle bir kayıt yok.
  Future<bool> unblock(int blockedSenderId) async {
    final row = await _db.blockedSenderById(blockedSenderId);
    if (row == null) return false;
    await _db.deleteBlockedSender(blockedSenderId);
    _settingsSync?.schedule(row.accountId);
    // Sunucu kuralı da gitmeli, yoksa ileti İstenmeyen'e düşmeye devam eder.
    _senderFilter?.request(row.accountId, force: true);
    await _moveMessages(
      accountId: row.accountId,
      from: SpecialUse.junk,
      to: SpecialUse.inbox,
      email: row.email,
    );
    return true;
  }

  Future<MailActionHandle?> _moveMessages({
    required int accountId,
    required SpecialUse from,
    required SpecialUse to,
    required String email,
  }) async {
    final source = await _db.mailboxBySpecialUse(accountId, from);
    if (source == null) return null;
    final rows = await _db.messagesFromSenders(
      mailboxId: source.id,
      emails: [email],
      serverBackedOnly: false,
    );
    if (rows.isEmpty) return null;
    return _mail.moveToMailbox(
      messageIds: [for (final row in rows) row.id],
      target: to,
    );
  }
}
