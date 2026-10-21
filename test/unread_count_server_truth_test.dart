import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/mail_connection.dart';
import 'package:kaydet/data/repositories/mail_repository.dart';
import 'package:kaydet/data/repositories/sync_engine.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/domain/models/mail_models.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

/// Arşiv ve özel klasörlerin okunmamış rozeti yerel ileti sayımından değil
/// SUNUCUDAN gelir (iletileri klasöre girilene kadar indirilmez). Bu sayı
/// sunucuyla ve listede görünen iletilerle uyuşmak zorundadır.
void main() {
  const customPath = 'INBOX.Emsoft';

  late AppDatabase db;
  late FakeImapService imap;
  late MailConnection connection;
  late SyncEngine sync;
  late MailRepository repository;
  late int accountId;

  Future<MailboxRow> custom() async =>
      (await db.mailboxByPath(accountId, customPath))!;

  Future<List<MessageRow>> customRows() async {
    final id = (await custom()).id;
    return (db.select(db.messages)..where((m) => m.mailboxId.equals(id))).get();
  }

  Future<int> storedCount() async => (await custom()).unreadCount;

  Future<void> refresh({Set<int>? only}) async {
    final result = await sync.refreshUnreadCounts(
      accountId,
      onlyMailboxIds: only,
    );
    expect(result, isA<Ok<int>>());
  }

  Future<void> drainQueue() async {
    await repository.waitForQueue();
    await repository.processQueue(accountId);
    await repository.waitForQueue();
  }

  Future<void> bootstrap({bool subscribed = true}) async {
    imap.mailboxes.add(
      RemoteMailbox(
        path: customPath,
        name: 'Emsoft',
        delimiter: '.',
        specialUse: SpecialUse.custom,
        isSubscribed: subscribed,
      ),
    );
    final result = await sync.syncMailboxes(accountId);
    expect(result, isA<Ok<List<MailboxRow>>>());
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
    repository = MailRepository(
      database: db,
      connection: connection,
      syncEngine: sync,
      smtpService: FakeSmtpService(),
    );
  });

  tearDown(() async {
    await connection.disconnect();
    await imap.dispose();
    await db.close();
  });

  test('abone görünmeyen özel klasörün rozeti de sunucudan gelir', () async {
    imap.store[customPath] = {
      1: envelope(uid: 1),
      2: envelope(uid: 2),
      3: envelope(uid: 3, seen: true),
    };
    await bootstrap(subscribed: false);

    await refresh();

    expect(await storedCount(), 2);
  });

  test('bayat kalmış rozet, sunucuda okunmamış kalmayınca sıfırlanır', () async {
    imap.store[customPath] = {
      1: envelope(uid: 1, seen: true),
      2: envelope(uid: 2, seen: true),
    };
    await bootstrap();
    // Önceki bir turdan kalan eski sayı (iletiler başka cihazda okundu).
    await db.setMailboxUnreadCount((await custom()).id, 2);

    await refresh();

    expect(await storedCount(), 0);
  });

  test(r'\Deleted işaretli okunmamış iletiler rozete sayılmaz', () async {
    imap.store[customPath] = {
      1: envelope(uid: 1),
      2: envelope(uid: 2, extraFlags: [r'\Deleted']),
      3: envelope(uid: 3, extraFlags: [r'\Deleted']),
    };
    await bootstrap();

    await refresh();

    // STATUS (UNSEEN) 3 der; listede görünen tek okunmamış ileti vardır.
    expect(await storedCount(), 1);
  });

  test('yerel sayımlı klasörler (Gelen Kutusu) yoklanmaz', () async {
    imap.store['INBOX'] = {1: envelope(uid: 1)};
    await bootstrap();

    await refresh();

    expect(imap.commandLog.where((c) => c == 'status:INBOX'), isEmpty);
  });

  test('doğrulanmış sayı değişmedikçe klasör yeniden seçilmez', () async {
    imap.store[customPath] = {
      1: envelope(uid: 1),
      2: envelope(uid: 2, extraFlags: [r'\Deleted']),
    };
    await bootstrap();

    await refresh();
    await refresh();

    expect(imap.commandLog.where((c) => c == 'countUnseen:$customPath'), hasLength(1));
    expect(await storedCount(), 1);
  });

  test('doğrulama başarısız olursa STATUS değeri kullanılır', () async {
    imap.store[customPath] = {1: envelope(uid: 1), 2: envelope(uid: 2)};
    await bootstrap();
    imap.failCountUnseen = const ServerFailure(detail: 'NO');

    await refresh();

    expect(await storedCount(), 2);
  });

  test('klasörde okundu işaretleyince sunucu ve rozet birlikte düşer', () async {
    imap.store[customPath] = {1: envelope(uid: 1), 2: envelope(uid: 2)};
    await bootstrap();
    await refresh();
    expect(await storedCount(), 2);
    final result = await sync.syncMailbox(
      accountId: accountId,
      mailbox: await custom(),
    );
    expect(result, isA<Ok<SyncOutcome>>());

    final rows = await customRows();
    await repository.setSeen([rows.first.id], true);
    expect(await storedCount(), 1, reason: 'yerel düzeltme hemen görünür');
    await drainQueue();

    // Sunucu gerçekten güncellendi ve rozet sunucudan geri okundu.
    expect(
      imap.store[customPath]!.values.where((e) => e.isSeen),
      hasLength(1),
    );
    expect(await storedCount(), 1);

    await repository.setSeen([rows.last.id], true);
    await drainQueue();
    expect(await storedCount(), 0);
  });

  test('okunmamış iletiyi klasörden silmek rozeti düşürür', () async {
    imap.store[customPath] = {1: envelope(uid: 1), 2: envelope(uid: 2)};
    await bootstrap();
    await refresh();
    await sync.syncMailbox(accountId: accountId, mailbox: await custom());

    final rows = await customRows();
    await repository.deleteMessages([rows.first.id]);
    expect(await storedCount(), 1, reason: 'yerel düzeltme hemen görünür');
    await drainQueue();

    expect(await storedCount(), 1);
    expect(imap.store[customPath]!.length, 1);
  });

  test('klasörde okunmamış iletinin geri alınan silmesi rozeti geri verir', () async {
    imap.store[customPath] = {1: envelope(uid: 1), 2: envelope(uid: 2)};
    await bootstrap();
    await refresh();
    await sync.syncMailbox(accountId: accountId, mailbox: await custom());

    final rows = await customRows();
    final handle = await repository.deleteMessages(
      [rows.first.id],
      undoWindow: const Duration(minutes: 5),
    );
    expect(await storedCount(), 1);

    expect(await handle!.undo(), isTrue);

    expect(await storedCount(), 2);
  });

  test(r'başka istemcinin sonradan koyduğu \Deleted bayrağı eşitlenir', () async {
    imap.store['INBOX'] = {1: envelope(uid: 1), 2: envelope(uid: 2)};
    await bootstrap();
    final inbox = (await db.mailboxBySpecialUse(accountId, SpecialUse.inbox))!;
    await sync.syncMailbox(accountId: accountId, mailbox: inbox);
    expect(await db.countUnread(inbox.id), 2);

    // Başka bir istemci 2. iletiyi silinmek üzere işaretledi (EXPUNGE yok).
    imap.store['INBOX']![2] = envelope(uid: 2, extraFlags: [r'\Deleted']);
    await sync.syncMailbox(
      accountId: accountId,
      mailbox: (await db.mailboxById(inbox.id))!,
    );

    expect(await db.countUnread(inbox.id), 1);
  });
}
