import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/mail_connection.dart';
import 'package:kaydet/data/repositories/sync_engine.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/domain/models/mail_models.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

/// Bildirim hedefi için tek ileti çekme ve tam eşitlemeyle birlikte çalışması.
void main() {
  late AppDatabase db;
  late FakeImapService imap;
  late MailConnection connection;
  late SyncEngine sync;
  late int accountId;
  late MailboxRow inbox;

  Future<MailboxRow> freshInbox() async => (await db.mailboxById(inbox.id))!;

  Future<void> syncInbox() async {
    final result = await sync.syncMailbox(
      accountId: accountId,
      mailbox: await freshInbox(),
    );
    expect(result, isA<Ok<SyncOutcome>>());
  }

  setUp(() async {
    db = createTestDatabase();
    imap = FakeImapService();
    final secureStore = InMemorySecureStore();
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
    );
    sync = SyncEngine(database: db, connection: connection);
    final mailboxes = await sync.syncMailboxes(accountId);
    inbox = (mailboxes as Ok<List<MailboxRow>>).value.firstWhere(
      (m) => m.specialUse == SpecialUse.inbox,
    );
  });

  tearDown(() async {
    await connection.disconnect();
    await imap.dispose();
    await db.close();
  });

  test('yalnızca istenen ileti ve gövdesi yazılır', () async {
    imap.seedInbox([for (var uid = 1; uid <= 60; uid++) envelope(uid: uid)]);
    imap.seedBody('INBOX', 60, const FetchedBody(plainText: 'merhaba'));

    final result = await sync.fetchMessageByUid(
      accountId: accountId,
      mailbox: await freshInbox(),
      uid: 60,
    );

    final rowId = (result as Ok<int?>).value;
    expect(rowId, isNotNull);
    expect(await db.uidsOf(inbox.id), [60]);
    expect((await db.messageById(rowId!))!.bodyFetchedAt, isNotNull);
    expect(imap.commandLog.where((c) => c.startsWith('fetch:')), ['fetch:1']);
  });

  test('sunucuda olmayan UID için Ok(null) döner, hiçbir şey yazılmaz', () async {
    imap.seedInbox([envelope(uid: 1)]);

    final result = await sync.fetchMessageByUid(
      accountId: accountId,
      mailbox: await freshInbox(),
      uid: 500,
    );

    expect((result as Ok<int?>).value, isNull);
    expect(await db.uidsOf(inbox.id), isEmpty);
  });

  test('UIDVALIDITY bildirimdekinden farklıysa ileti çekilmez', () async {
    imap.seedInbox([envelope(uid: 1)]);

    final result = await sync.fetchMessageByUid(
      accountId: accountId,
      mailbox: await freshInbox(),
      uid: 1,
      expectedUidValidity: imap.uidValidity + 1,
    );

    expect((result as Ok<int?>).value, isNull);
    expect(await db.uidsOf(inbox.id), isEmpty);
  });

  test('öne alınan tek ileti, aradaki iletilerin eşitlenmesini engellemez', () async {
    imap.seedInbox([envelope(uid: 1), envelope(uid: 2)]);
    await syncInbox();
    expect(await db.uidsOf(inbox.id), unorderedEquals([1, 2]));

    // Arada üç ileti geldi; bildirim yalnızca sonuncusu (uid 5) içindi.
    imap.seedInbox([envelope(uid: 3), envelope(uid: 4), envelope(uid: 5)]);
    await sync.fetchMessageByUid(
      accountId: accountId,
      mailbox: await freshInbox(),
      uid: 5,
    );
    expect(await db.highestUid(inbox.id), 5);

    await syncInbox();

    expect(await db.uidsOf(inbox.id), unorderedEquals([1, 2, 3, 4, 5]));
  });
}
