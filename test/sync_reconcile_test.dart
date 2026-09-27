import 'package:drift/drift.dart' show Value;
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

/// Eşitlemenin sunucu durumunu yerelle nasıl uzlaştırdığı: boşalan klasör,
/// değişiklik yokken atlanan taramalar, geçici hatada ilerletilmeyen kayıt,
/// gövde önbelleğinin onarımı ve UIDVALIDITY korumaları.
void main() {
  late AppDatabase db;
  late FakeImapService imap;
  late InMemorySecureStore secureStore;
  late MailConnection connection;
  late SyncEngine sync;
  late MailRepository repository;
  late int accountId;
  late MailboxRow inbox;

  Future<MailboxRow> freshInbox() async => (await db.mailboxById(inbox.id))!;

  Future<SyncOutcome> syncInbox() async {
    final result = await sync.syncMailbox(
      accountId: accountId,
      mailbox: await freshInbox(),
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
    );
    sync = SyncEngine(database: db, connection: connection);
    repository = MailRepository(
      database: db,
      connection: connection,
      syncEngine: sync,
      smtpService: FakeSmtpService(),
    );

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

  group('boşalan klasör', () {
    test('sunucuda ileti kalmayınca yerel hayalet iletiler silinir', () async {
      imap.seedInbox([envelope(uid: 1), envelope(uid: 2)]);
      await syncInbox();
      expect(await db.uidsOf(inbox.id), unorderedEquals([1, 2]));

      // Başka bir cihazdan Gelen Kutusu boşaltıldı.
      imap.store['INBOX']!.clear();
      final outcome = await syncInbox();

      expect(await db.uidsOf(inbox.id), isEmpty);
      expect(outcome.deletedCount, 2);
    });

    test('boşaltılan klasöre gelen ilk ileti "yeni" sayılır', () async {
      imap.seedInbox([envelope(uid: 1)]);
      await syncInbox();
      imap.store['INBOX']!.clear();
      await syncInbox();

      imap.seedInbox([envelope(uid: 5)]);
      final outcome = await syncInbox();

      // İlk indirme sayılsaydı bildirim bastırılır ve kullanıcı bu iletiden
      // haberdar edilmezdi.
      expect(outcome.initialDownload, isFalse);
      expect(outcome.newMessageIds, hasLength(1));
      expect(await db.uidsOf(inbox.id), [5]);
    });

    test('yerel taslaklar boşalan klasörde korunur', () async {
      imap.seedInbox([envelope(uid: 1)]);
      await syncInbox();
      final draftId = await db.insertLocalMessage(
        MessagesCompanion.insert(
          accountId: accountId,
          mailboxId: inbox.id,
          dateUtc: DateTime.utc(2026, 9, 14),
          subject: const Value('Taslak'),
          isLocalOnly: const Value(true),
          isDraft: const Value(true),
        ),
      );

      imap.store['INBOX']!.clear();
      await syncInbox();

      expect(await db.uidsOf(inbox.id), isEmpty);
      expect(await db.messageById(draftId), isNotNull);
    });
  });

  group('gereksiz tarama yapılmaz', () {
    test('sunucuda değişiklik yokken UID SEARCH atlanır', () async {
      imap.seedInbox([envelope(uid: 1)]);
      await syncInbox();
      imap.commandLog.clear();

      await syncInbox();

      expect(imap.commandLog.where((c) => c == 'search'), isEmpty);
    });

    test('yeni ileti gelince silinenler de taranır', () async {
      imap.seedInbox([envelope(uid: 1)]);
      await syncInbox();
      imap.seedInbox([envelope(uid: 2)]);
      imap.commandLog.clear();

      final outcome = await syncInbox();

      expect(outcome.newMessageIds, hasLength(1));
      expect(imap.commandLog.where((c) => c == 'search'), isNotEmpty);
    });

    test('bir iletinin silinmesi (yeni ileti olmadan) fark edilir', () async {
      imap.seedInbox([envelope(uid: 1), envelope(uid: 2)]);
      await syncInbox();

      imap.store['INBOX']!.remove(1);
      final outcome = await syncInbox();

      expect(outcome.deletedCount, 1);
      expect(await db.uidsOf(inbox.id), [2]);
    });
  });

  group('geçici hata', () {
    test('bayraklar alınamazsa sunucu durumu ilerletilmez, sonraki tur dener',
        () async {
      imap.seedInbox([envelope(uid: 1)]);
      await syncInbox();
      expect((await freshInbox()).uidNext, 2);

      imap.seedInbox([envelope(uid: 2)]);
      imap.failFlags = const ServerFailure(detail: 'zaman aşımı');
      final failed = await syncInbox();

      // Yeni ileti yine de indirildi, ama uzlaşma tamamlanmadığı için kayıt
      // ilerlemedi: CONDSTORE'da bu, kaçan bayrak değişikliğinin kalıcı olarak
      // kaybolması demekti.
      expect(failed.newMessageIds, hasLength(1));
      expect(await db.uidsOf(inbox.id), unorderedEquals([1, 2]));
      expect((await freshInbox()).uidNext, 2);

      imap.failFlags = null;
      await syncInbox();
      expect((await freshInbox()).uidNext, 3);
    });
  });

  group('gövde ön-yükleme', () {
    test('bağlantı başka bir hesaba geçtiyse hiçbir şey çekilmez', () async {
      final otherId = await db.insertAccount(
        AccountsCompanion.insert(
          email: 'baska@pazarlik.com.tr',
          username: 'baska@pazarlik.com.tr',
          imapHost: 'mail.pazarlik.com.tr',
          smtpHost: 'mail.pazarlik.com.tr',
        ),
      );
      await secureStore.writePassword(otherId, 'sifre');

      imap.seedInbox([envelope(uid: 1), envelope(uid: 2)]);
      await syncInbox();

      // Ön-yükleme sürerken kullanıcı hesap değiştirdi: bağlantı artık başka
      // hesaba ait. Bu hesabın UID'leri orada çekilseydi başka bir iletinin
      // gövdesi buradaki satıra yazılırdı.
      await connection.ensureConnected(otherId);
      expect(connection.isConnectedTo(accountId), isFalse);
      imap.commandLog.clear();

      await sync.prefetchBodies(accountId: accountId, mailbox: inbox);

      expect(imap.commandLog.where((c) => c.startsWith('body:')), isEmpty);
    });

    test('bağlı hesapta gövdeler indirilip yazılır', () async {
      imap.seedInbox([envelope(uid: 1)]);
      imap.seedBody(
        'INBOX',
        1,
        const FetchedBody(plainText: 'Merhaba, toplantı yarın.'),
      );
      await syncInbox();

      await sync.prefetchBodies(accountId: accountId, mailbox: inbox);

      final message = (await db.messageByUid(inbox.id, 1))!;
      expect(message.bodyFetchedAt, isNotNull);
      expect(message.preview, contains('toplantı yarın'));
      expect((await db.bodyOf(message.id))!.plainText, contains('Merhaba'));
    });
  });

  group('ensureBody', () {
    test('gövde satırı silinmişse (eski önbellek temizleme) yeniden indirir',
        () async {
      imap.seedInbox([envelope(uid: 1)]);
      imap.seedBody('INBOX', 1, const FetchedBody(plainText: 'gerçek gövde'));
      await syncInbox();
      final message = (await db.messageByUid(inbox.id, 1))!;

      // Eski sürüm: gövde satırı silinir, `bodyFetchedAt` dolu kalırdı.
      await db.upsertBody(messageId: message.id, plainText: 'geçici');
      await (db.delete(
        db.messageBodies,
      )..where((b) => b.messageId.equals(message.id))).go();
      expect((await db.messageById(message.id))!.bodyFetchedAt, isNotNull);
      expect(await db.bodyOf(message.id), isNull);

      final result = await repository.ensureBody(message.id);

      expect(result.isOk, isTrue);
      expect((await db.bodyOf(message.id))!.plainText, 'gerçek gövde');
    });

    test('gövde zaten yerelde varsa sunucuya gidilmez', () async {
      imap.seedInbox([envelope(uid: 1)]);
      await syncInbox();
      final message = (await db.messageByUid(inbox.id, 1))!;
      await db.upsertBody(messageId: message.id, plainText: 'yerel');
      imap.commandLog.clear();

      final result = await repository.ensureBody(message.id);

      expect(result.isOk, isTrue);
      expect(imap.commandLog.where((c) => c.startsWith('body:')), isEmpty);
    });

    test('eşzamanlı gövde indirmeleri klasör seçimini karıştırmaz', () async {
      imap.seedInbox([envelope(uid: 1)]);
      imap.seedBody('INBOX', 1, const FetchedBody(plainText: 'gelen kutusu'));
      imap.store['INBOX.Archive'] = {2: envelope(uid: 2)};
      imap.seedBody(
        'INBOX.Archive',
        2,
        const FetchedBody(plainText: 'arşiv'),
      );
      await syncInbox();
      final archive = (await db.mailboxesOf(accountId)).firstWhere(
        (m) => m.specialUse == SpecialUse.archive,
      );
      await sync.syncMailbox(accountId: accountId, mailbox: archive);

      final inboxMessage = (await db.messageByUid(inbox.id, 1))!;
      final archiveMessage = (await db.messageByUid(archive.id, 2))!;
      imap.bodyDelay = const Duration(milliseconds: 15);

      await Future.wait([
        repository.ensureBody(inboxMessage.id),
        repository.ensureBody(archiveMessage.id),
      ]);

      // Her ileti KENDİ klasörünün gövdesini aldı.
      expect((await db.bodyOf(inboxMessage.id))!.plainText, 'gelen kutusu');
      expect((await db.bodyOf(archiveMessage.id))!.plainText, 'arşiv');
    });
  });

  group('kuyruktaki işlemler', () {
    test('UIDVALIDITY değişmişse eski UID\'lerle işlem uygulanmaz', () async {
      imap.seedInbox([envelope(uid: 1)]);
      await syncInbox();
      final message = (await db.messageByUid(inbox.id, 1))!;

      // Yerel kayıt eski UIDVALIDITY'yi gösteriyor; sunucu artık başka bir
      // değer bildiriyor (klasör yeniden numaralanmış).
      await db.updateMailboxSync(inbox.id, uidValidity: imap.uidValidity + 1);
      imap.commandLog.clear();

      await repository.setSeen([message.id], true);
      await repository.waitForQueue();

      expect(imap.commandLog.any((c) => c.startsWith('store:')), isFalse);
      expect(await db.select(db.pendingOperations).get(), isEmpty);
    });

    test('UIDVALIDITY aynıysa işlem uygulanır', () async {
      imap.seedInbox([envelope(uid: 1)]);
      await syncInbox();
      final message = (await db.messageByUid(inbox.id, 1))!;
      imap.commandLog.clear();

      await repository.setSeen([message.id], true);
      await repository.waitForQueue();

      expect(imap.commandLog.any((c) => c.contains(r'store:\Seen:+')), isTrue);
    });

    test('kuyruk turu sürerken eklenen işlem aynı turda işlenir', () async {
      imap.seedInbox([envelope(uid: 1), envelope(uid: 2)]);
      await syncInbox();
      final first = (await db.messageByUid(inbox.id, 1))!;
      final second = (await db.messageByUid(inbox.id, 2))!;
      imap.commandLog.clear();

      // İkinci istek, birincinin turu sürerken gelir (kilit altında bekler).
      await repository.setSeen([first.id], true);
      await repository.setSeen([second.id], true);
      await repository.waitForQueue();

      expect(await db.select(db.pendingOperations).get(), isEmpty);
      expect(
        imap.commandLog.where((c) => c.contains(r'store:\Seen:+')),
        hasLength(2),
      );
    });
  });
}
