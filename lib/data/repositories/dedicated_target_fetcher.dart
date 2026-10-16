import '../../core/mail_log.dart';
import '../../core/result.dart';
import '../database/app_database.dart';
import '../services/imap_service.dart';
import '../services/secure_store.dart';
import 'mail_connection.dart';
import 'sync_engine.dart';

/// Bildirim hedefi için tek bir iletiyi AYRI, kısa ömürlü bir IMAP
/// bağlantısıyla getirir.
///
/// Ana bağlantı (bkz. `MailConnection`) uzun bir eşitlemenin — klasör listesi,
/// Gelen Kutusu, geri doldurma — işlem kilidini tutarken sıradaki işlemler
/// bekler; bildirimden açılan ileti de bu kuyruğun sonuna düşerdi. Ayrı bağlantı
/// kilidi paylaşmaz: `SELECT` + `UID FETCH` doğrudan çalışır. Yazım aynı
/// veritabanına yapıldığı için ana bağlantıdaki eşitleme sonucu bozulmaz (bkz.
/// `SyncEngine.fetchMessageByUid`).
///
/// Bağlantı iş bitince kapatılır: sunucunun eşzamanlı bağlantı sınırı boşuna
/// tüketilmez. Açılamazsa (ör. "Too many connections") hata döner; çağıran ana
/// bağlantıya geçer.
class DedicatedTargetFetcher {
  DedicatedTargetFetcher({
    required AppDatabase database,
    required SecureStore secureStore,
    ImapService Function()? imapFactory,
  }) : _db = database,
       _secureStore = secureStore,
       _imapFactory = imapFactory ?? EnoughMailImapService.new;

  final AppDatabase _db;
  final SecureStore _secureStore;
  final ImapService Function() _imapFactory;

  Future<Result<int?>> call({
    required int accountId,
    required MailboxRow mailbox,
    required int uid,
    int? expectedUidValidity,
  }) async {
    final imap = _imapFactory();
    final connection = MailConnection(
      database: _db,
      secureStore: _secureStore,
      imapService: imap,
      keepAlive: false,
    );
    try {
      MailLog.remote('target fetch: dedicated connection account=$accountId');
      return await SyncEngine(database: _db, connection: connection)
          .fetchMessageByUid(
            accountId: accountId,
            mailbox: mailbox,
            uid: uid,
            expectedUidValidity: expectedUidValidity,
          );
    } finally {
      await connection.disconnect();
      if (imap is EnoughMailImapService) await imap.dispose();
    }
  }
}
