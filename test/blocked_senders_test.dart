import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/blocked_sender_repository.dart';
import 'package:kaydet/data/repositories/mail_connection.dart';
import 'package:kaydet/data/repositories/mail_repository.dart';
import 'package:kaydet/data/repositories/sync_engine.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/domain/models/mail_models.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

/// Engellenen kullanıcılar: engellenen göndericinin iletileri SUNUCUDA İstenmeyen'e taşınır
/// (yalnızca yerelde gizlenmez), engel kalkınca geri gelir. Web istemcisiyle aynı kurallar.
void main() {
  late AppDatabase db;
  late FakeImapService imap;
  late InMemorySecureStore secureStore;
  late MailConnection connection;
  late SyncEngine sync;
  late MailRepository repository;
  late BlockedSenderRepository blocking;
  late int accountId;
  late MailboxRow inbox;
  late MailboxRow junk;

  const noisy = 'gurultu@spam.example';

  Future<SyncOutcome> syncBox(MailboxRow box) async {
    final result = await sync.syncMailbox(
      accountId: accountId,
      mailbox: (await db.mailboxById(box.id))!,
    );
    return (result as Ok<SyncOutcome>).value;
  }

  setUp(() async {
    db = createTestDatabase();
    imap = FakeImapService();
    secureStore = InMemorySecureStore();
    accountId = await db.insertAccount(
      AccountsCompanion.insert(
        email: 'info@pazarlik.com.tr',
        username: 'info@pazarlik.com.tr',
        imapHost: 'mail.pazarlik.com.tr',
        smtpHost: 'mail.pazarlik.com.tr',
      ),
    );
    await secureStore.writePassword(accountId, 'sifre');
    connection = MailConnection(
      database: db,
      secureStore: secureStore,
      imapService: imap,
      keepAlive: false,
    );
    sync = SyncEngine(database: db, connection: connection);
    repository = MailRepository(
      database: db,
      connection: connection,
      syncEngine: sync,
      smtpService: FakeSmtpService(),
    );
    blocking = BlockedSenderRepository(database: db, mail: repository);

    final boxes =
        ((await sync.syncMailboxes(accountId)) as Ok<List<MailboxRow>>).value;
    inbox = boxes.firstWhere((m) => m.specialUse == SpecialUse.inbox);
    junk = boxes.firstWhere((m) => m.specialUse == SpecialUse.junk);
  });

  tearDown(() async {
    await connection.disconnect();
    await imap.dispose();
    await db.close();
  });

  group('senkronizasyon taraması', () {
    test('engellenen göndericinin yeni iletisi sunucuda İstenmeyen\'e taşınır, yerelden gider, "yeni" sayılmaz', () async {
      imap.seedInbox([envelope(uid: 1, fromEmail: 'dost@musteri.com')]);
      await syncBox(inbox); // ilk indirme
      await db.insertBlockedSender(accountId: accountId, email: noisy);

      imap.seedInbox([
        envelope(uid: 2, fromEmail: 'Gurultu@Spam.Example'), // büyük/küçük harfe duyarsız
        envelope(uid: 3, fromEmail: 'dost@musteri.com'),
      ]);
      final outcome = await syncBox(inbox);

      expect(imap.store['INBOX']!.keys, unorderedEquals([1, 3]));
      expect(imap.store['INBOX.Junk']!.values.map((e) => e.from!.email), ['Gurultu@Spam.Example']);
      expect(await db.uidsOf(inbox.id), unorderedEquals([1, 3]));
      // Engelli göndericiden gelen ileti bildirim üretmemeli.
      expect(outcome.newMessageIds, hasLength(1));

      // İstenmeyen klasörü senkronize edilince ileti orada görünür.
      await syncBox(junk);
      expect(await db.uidsOf(junk.id), hasLength(1));
    });

    test('önceki turdan kalan engelli ileti de sonraki turda taşınır', () async {
      imap.seedInbox([envelope(uid: 1, fromEmail: noisy)]);
      await syncBox(inbox);
      expect(await db.uidsOf(inbox.id), [1]);

      await db.insertBlockedSender(accountId: accountId, email: noisy);
      imap.seedInbox([envelope(uid: 2, fromEmail: 'dost@musteri.com')]);
      await syncBox(inbox);

      expect(imap.store['INBOX']!.keys, [2]);
      expect(await db.uidsOf(inbox.id), [2]);
    });

    test('taşıma başarısız olursa hiçbir şey değişmez ve sonraki tur yeniden dener', () async {
      imap.seedInbox([envelope(uid: 1, fromEmail: 'dost@musteri.com')]);
      await syncBox(inbox);
      await db.insertBlockedSender(accountId: accountId, email: noisy);
      imap.seedInbox([envelope(uid: 2, fromEmail: noisy)]);

      imap.failMove = const ConnectionFailure(detail: 'yok');
      await syncBox(inbox);
      expect(await db.uidsOf(inbox.id), unorderedEquals([1, 2]));
      expect(imap.store['INBOX']!.keys, unorderedEquals([1, 2]));

      imap.failMove = null;
      await syncBox(inbox);
      expect(imap.store['INBOX']!.keys, [1]);
      expect(await db.uidsOf(inbox.id), [1]);
    });

    test('engelli kimse yoksa hiçbir taşıma komutu gitmez', () async {
      imap.seedInbox([envelope(uid: 1, fromEmail: noisy)]);
      await syncBox(inbox);
      expect(imap.commandLog.where((c) => c.startsWith('move:')), isEmpty);
    });
  });

  group('engelle / engeli kaldır', () {
    test('engellemek Gelen Kutusu\'ndaki mevcut iletileri İstenmeyen\'e taşır; ikinci kez engellemek bir şey yapmaz', () async {
      imap.seedInbox([
        envelope(uid: 1, fromEmail: noisy),
        envelope(uid: 2, fromEmail: 'dost@musteri.com'),
      ]);
      await syncBox(inbox);

      final first = await blocking.block(accountId: accountId, email: ' Gurultu@Spam.Example ');
      expect(first.outcome, BlockOutcome.blocked);
      expect(first.row!.email, noisy);
      await repository.waitForQueue();

      expect(imap.store['INBOX']!.keys, [2]);
      expect(imap.store['INBOX.Junk']!.values.map((e) => e.from!.email), [noisy]);
      expect(await db.uidsOf(inbox.id), [2]);

      final again = await blocking.block(accountId: accountId, email: noisy);
      expect(again.outcome, BlockOutcome.alreadyBlocked);
      expect((await db.blockedSendersOf(accountId)), hasLength(1));
    });

    test('geçersiz adres ve hesabın kendi adresi engellenmez', () async {
      expect((await blocking.block(accountId: accountId, email: 'adres-degil')).outcome, BlockOutcome.invalidAddress);
      expect((await blocking.block(accountId: accountId, email: 'INFO@pazarlik.com.tr')).outcome, BlockOutcome.ownAddress);
      expect(await db.blockedSendersOf(accountId), isEmpty);
    });

    test('engeli kaldırmak İstenmeyen\'deki iletileri Gelen Kutusu\'na taşır ve adresi listeden siler', () async {
      imap.store['INBOX.Junk'] = {
        5: envelope(uid: 5, fromEmail: noisy),
        6: envelope(uid: 6, fromEmail: 'baska@spam.example'),
      };
      await syncBox(junk);
      final blocked = await blocking.block(accountId: accountId, email: noisy);
      await repository.waitForQueue();

      expect(await blocking.unblock(blocked.row!.id), isTrue);
      await repository.waitForQueue();

      expect(await db.blockedSendersOf(accountId), isEmpty);
      expect(imap.store['INBOX.Junk']!.keys, [6]); // başka göndericiye dokunulmaz
      expect(imap.store['INBOX']!.values.map((e) => e.from!.email), [noisy]);
      expect(await blocking.unblock(blocked.row!.id), isFalse);
    });
  });
}
