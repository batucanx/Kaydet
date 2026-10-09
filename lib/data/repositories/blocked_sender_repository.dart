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
/// adres listeden çıkar, yeni iletiler Gelen Kutusu'na düşer; İstenmeyen'dekiler yerinde kalır. Liste, ayar belgesi
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

  /// "İstenmeyen olarak işaretle" (web ile aynı kural): göndericiler listeye girer, Gelen Kutusu'ndaki
  /// iletileri İstenmeyen'e taşınır ve bundan sonra gelenler de oraya gider. Verilen iletiler
  /// hangi klasördeyse İstenmeyen'e taşınır; zaten İstenmeyen'dekiler yerinde kalır, yalnızca
  /// göndericisi listelenir. Dönüş: en az bir ileti İstenmeyen'e taşındı mı.
  Future<bool> markSpam(List<int> messageIds) async {
    final rows = await _db.messagesByIds(messageIds);
    if (rows.isEmpty) return false;

    final listed = <(int, String)>{};
    for (final row in rows) {
      final email = row.fromEmail.trim().toLowerCase();
      if (row.isLocalOnly || email.isEmpty) continue;
      if (!listed.add((row.accountId, email))) continue;
      await block(accountId: row.accountId, email: email, name: row.fromName);
    }

    final movedAny = (await _rowsInJunk(rows)).length < rows.length;
    await _mail.moveToMailbox(messageIds: messageIds, target: SpecialUse.junk);
    return movedAny;
  }

  /// "İstenmeyen değil olarak işaretle": göndericiler listeden çıkar (sunucu kuralı da). İstenmeyen'deki
  /// iletiler Gelen Kutusu'na döner; başka klasördekilerde yalnızca gönderici listeden çıkar.
  Future<({bool restored, MailActionHandle? handle})> markNotSpam(
    List<int> messageIds, {
    Duration undoWindow = Duration.zero,
  }) async {
    final rows = await _db.messagesByIds(messageIds);
    if (rows.isEmpty) return (restored: false, handle: null);
    await _unlistSendersOf(rows);
    final inJunk = await _rowsInJunk(rows);
    if (inJunk.isEmpty) return (restored: false, handle: null);
    final handle = await _mail.restoreToInbox([
      for (final row in inJunk) row.id,
    ], undoWindow: undoWindow);
    return (restored: true, handle: handle);
  }

  /// İstenmeyen'deki bu iletilerden birinin göndericisi hâlâ listede mi? Öyleyse iletiyi Gelen Kutusu'na
  /// almadan önce kullanıcıya sorulur (liste durursa sonraki tarama iletiyi yeniden İstenmeyen'e iterdi).
  Future<bool> hasListedSenderInJunk(List<int> messageIds) async {
    final inJunk = await _rowsInJunk(await _db.messagesByIds(messageIds));
    final blocked = <int, Set<String>>{};
    for (final row in inJunk) {
      final listed = blocked[row.accountId] ??= await _db.blockedEmails(
        row.accountId,
      );
      if (listed.contains(row.fromEmail.trim().toLowerCase())) return true;
    }
    return false;
  }

  /// Bu iletilerin göndericilerini listeden çıkarır (iletilere dokunmaz).
  Future<void> unlistSendersOf(List<int> messageIds) async =>
      _unlistSendersOf(await _db.messagesByIds(messageIds));

  Future<void> _unlistSendersOf(List<MessageRow> rows) async {
    final seen = <(int, String)>{};
    for (final row in rows) {
      final email = row.fromEmail.trim().toLowerCase();
      if (email.isEmpty || !seen.add((row.accountId, email))) continue;
      for (final entry in await _db.blockedSendersOf(row.accountId)) {
        if (entry.email == email) await _unlist(entry);
      }
    }
  }

  Future<List<MessageRow>> _rowsInJunk(List<MessageRow> rows) async {
    final junkByAccount = <int, int?>{};
    final out = <MessageRow>[];
    for (final row in rows) {
      final junkId = junkByAccount[row.accountId] ??=
          (await _db.mailboxBySpecialUse(row.accountId, SpecialUse.junk))?.id;
      if (junkId != null && junkId == row.mailboxId) out.add(row);
    }
    return out;
  }

  Future<void> _unlist(BlockedSenderRow row) async {
    await _db.deleteBlockedSender(row.id);
    _settingsSync?.schedule(row.accountId);
    // Sunucu kuralı da gitmeli, yoksa ileti İstenmeyen'e düşmeye devam eder.
    _senderFilter?.request(row.accountId, force: true);
  }

  /// Ayarlar'daki listeden çıkarır (web ile aynı): yalnızca yeni iletiler Gelen Kutusu'na ulaşır,
  /// İstenmeyen'deki mevcut iletiler yerinde kalır. `false`: böyle bir kayıt yok.
  Future<bool> unblock(int blockedSenderId) async {
    final row = await _db.blockedSenderById(blockedSenderId);
    if (row == null) return false;
    await _unlist(row);
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
