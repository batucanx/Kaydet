import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/mail_connection.dart';
import 'package:kaydet/data/repositories/sync_engine.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/domain/models/mail_models.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

void main() {
  group('Klasör İleti Sayısı ve Veri Tutarlılığı (Sunucu ile Birebir Eşitlik)', () {
    late AppDatabase db;
    late FakeImapService imap;
    late MailConnection connection;
    late SyncEngine sync;
    late int accountId;
    late MailboxRow archiveBox;

    setUp(() async {
      db = createTestDatabase();
      imap = FakeImapService();
      final secureStore = InMemorySecureStore();
      accountId = await db.insertAccount(
        AccountsCompanion.insert(
          email: 'test@archive-sync.com',
          username: 'test@archive-sync.com',
          imapHost: 'mail.archive-sync.com',
          smtpHost: 'mail.archive-sync.com',
        ),
      );
      await secureStore.writePassword(accountId, 'pass');
      connection = MailConnection(
        database: db,
        secureStore: secureStore,
        imapService: imap,
      );
      sync = SyncEngine(database: db, connection: connection);

      final boxes = await sync.syncMailboxes(accountId);
      archiveBox = (boxes as Ok<List<MailboxRow>>).value.firstWhere(
        (m) => m.specialUse == SpecialUse.archive,
      );
    });

    tearDown(() async {
      await connection.disconnect();
      await imap.dispose();
      await db.close();
    });

    test(
      'Sunucuda 25, mobilde 28 ileti olduğunda (3 ileti sunucuda silinmiş/taşınmışsa) senkronizasyon yereldeki 3 hayalet iletiyi temizler ve 25e eşitler',
      () async {
        // 1. Durum: Başlangıçta sunucuda ve mobilde 28 ileti var (UID 1..28)
        final initialEnvelopes = [
          for (var i = 1; i <= 28; i++)
            envelope(
              uid: i,
              subject: 'Arşiv İletisi $i',
              date: DateTime.utc(2026, 1, 1).add(Duration(days: i)),
            ),
        ];
        imap.seedMailbox(archiveBox.path, initialEnvelopes);

        // İlk senkron: yerelde 28 ileti oluşur
        final outcome1 = await sync.syncMailbox(
          accountId: accountId,
          mailbox: archiveBox,
        );
        expect(outcome1, isA<Ok<SyncOutcome>>());
        expect(await db.countMessages(archiveBox.id), 28);

        // 2. Durum: Sunucu tarafında (Webmail vb.) 3 ileti silindi (ör. UID 26, 27, 28)
        // Artık sunucuda yalnızca 25 ileti var (UID 1..25)
        imap.store[archiveBox.path]!.remove(26);
        imap.store[archiveBox.path]!.remove(27);
        imap.store[archiveBox.path]!.remove(28);

        // Sunucunun yeni durumu: messageCount = 25
        expect(imap.store[archiveBox.path]!.length, 25);

        // Güncel mailbox satırını oku (önceki totalCount = 28 idi)
        final currentBox = await db.mailboxById(archiveBox.id);
        expect(currentBox!.totalCount, 28);

        // İkinci senkron: Mobil sunucuya bağlanır ve eşitler
        final outcome2 = await sync.syncMailbox(
          accountId: accountId,
          mailbox: currentBox,
        );
        expect(outcome2, isA<Ok<SyncOutcome>>());
        final outcomeValue = (outcome2 as Ok<SyncOutcome>).value;

        // 3 iletinin silindiği doğrulanır
        expect(outcomeValue.deletedCount, 3);

        // Yerel veritabanındaki ileti sayısı ARTIK TAM OLARAK 25'tir!
        final localCountAfterSync = await db.countMessages(archiveBox.id);
        expect(localCountAfterSync, 25);

        // Silinen UID'ler artık veritabanında yoktur
        final remainingUids = await db.uidsOf(archiveBox.id);
        expect(remainingUids.contains(26), isFalse);
        expect(remainingUids.contains(27), isFalse);
        expect(remainingUids.contains(28), isFalse);
      },
    );

    test(
      'needsInitialFetch durumunda yerelde eski/hayalet kayıtlar kalmışsa bunlar temizlenir',
      () async {
        // Yerel veritabanında önceden kalmış 3 hayalet ileti olsun (UID 991, 992, 993)
        for (final uid in [991, 992, 993]) {
          await db.into(db.messages).insert(
            MessagesCompanion.insert(
              accountId: accountId,
              mailboxId: archiveBox.id,
              uid: Value(uid),
              subject: Value('Hayalet İleti $uid'),
              dateUtc: DateTime.utc(2025, 1, 1),
            ),
          );
        }
        expect(await db.countMessages(archiveBox.id), 3);

        // Sunucuda ise gerçek 25 ileti var (UID 1..25)
        final serverEnvelopes = [
          for (var i = 1; i <= 25; i++)
            envelope(
              uid: i,
              subject: 'Sunucu Arşiv $i',
              date: DateTime.utc(2026, 1, 1).add(Duration(days: i)),
            ),
        ];
        imap.seedMailbox(archiveBox.path, serverEnvelopes);

        // mailbox.uidNext == null olduğunda needsInitialFetch tetiklenir
        final boxWithNullUidNext = archiveBox.copyWith(uidNext: const Value(null));
        final outcome = await sync.syncMailbox(
          accountId: accountId,
          mailbox: boxWithNullUidNext,
        );

        expect(outcome, isA<Ok<SyncOutcome>>());
        // 3 hayalet silindi, 25 yeni eklendi
        expect(await db.countMessages(archiveBox.id), 25);

        final uids = await db.uidsOf(archiveBox.id);
        expect(uids.contains(991), isFalse);
        expect(uids.contains(992), isFalse);
        expect(uids.contains(993), isFalse);
      },
    );

    test(
      'Sunucuya yeni iletiler taşındığında (sunucu 25, yerel 23), senkronizasyon eksikleri indirir ve yereli tam 25e eşitler',
      () async {
        // Sunucuda 25 ileti var
        final serverEnvelopes = [
          for (var i = 1; i <= 25; i++)
            envelope(
              uid: i,
              subject: 'Arşiv $i',
              date: DateTime.utc(2026, 1, 1).add(Duration(days: i)),
            ),
        ];
        imap.seedMailbox(archiveBox.path, serverEnvelopes);

        // İlk senkron: 25 ileti iner
        await sync.syncMailbox(accountId: accountId, mailbox: archiveBox);
        expect(await db.countMessages(archiveBox.id), 25);

        // Yerelde 2 ileti silinmiş gibi simüle edelim (veya eksik kalmış olsun)
        await db.deleteMessagesByUid(archiveBox.id, [24, 25]);
        expect(await db.countMessages(archiveBox.id), 23);

        // Yeniden senkronize edelim
        final currentBox = await db.mailboxById(archiveBox.id);
        final outcome = await sync.syncMailbox(
          accountId: accountId,
          mailbox: currentBox!,
        );

        expect(outcome, isA<Ok<SyncOutcome>>());
        // Eksik 2 ileti tamamlandı ve yerel tam 25 oldu
        expect(await db.countMessages(archiveBox.id), 25);
        final uids = await db.uidsOf(archiveBox.id);
        expect(uids.contains(24), isTrue);
        expect(uids.contains(25), isTrue);
      },
    );

    test(
      'watchMessages Arşiv klasöründe completeThreads ve sentMailboxId olsa bile yalnızca Arşiv iletilerini döndürür',
      () async {
        // Arşiv klasörüne 1 ileti ekle
        final archiveMsgId = await db.into(db.messages).insert(
          MessagesCompanion.insert(
            accountId: accountId,
            mailboxId: archiveBox.id,
            uid: const Value(1),
            threadId: const Value('thread-xyz'),
            subject: const Value('Sitenizdeki müşteri soruları'),
            dateUtc: DateTime.utc(2026, 10, 10),
          ),
        );

        // Gönderilenler kutusuna aynı threadId ile 3 giden ileti ekle
        final sentBox = await db.mailboxBySpecialUse(accountId, SpecialUse.sent);
        expect(sentBox, isNotNull);

        for (var i = 1; i <= 3; i++) {
          await db.into(db.messages).insert(
            MessagesCompanion.insert(
              accountId: accountId,
              mailboxId: sentBox!.id,
              uid: Value(100 + i),
              threadId: const Value('thread-xyz'),
              subject: Value('Yanıt: Sitenizdeki müşteri soruları $i'),
              dateUtc: DateTime.utc(2026, 10, 10 + i),
            ),
          );
        }

        // Arşiv klasörünü watchMessages ile dinle (providers.dart'taki gibi completeThreads: false)
        final messages = await db.watchMessages(
          accountId: accountId,
          mailboxId: archiveBox.id,
          sentMailboxId: null, // providers.dart'ta non-inbox için null
          completeThreads: false, // providers.dart'ta non-inbox için false
        ).first;

        // Arşiv kutusu YALNIZCA kendi 1 iletisini gösterir, Gönderilenler'deki 3 ileti Arşive sızmaz!
        expect(messages.length, 1);
        expect(messages.first.id, archiveMsgId);
      },
    );

    test(
      'cPanel/Dovecot senaryosu: sunucuda 3 ileti \\Deleted bayraklı olduğunda (Webmail 25 görürken IMAP ALL 28 görse bile), UNDELETED uzlaşması yereldeki 3 iletiyi siler ve 25e eşitler',
      () async {
        // 1. Durum: Sunucuda 28 ileti var (25 aktif + 3 tane \Deleted bayraklı silinmiş ileti)
        final envelopes = [
          for (var i = 1; i <= 25; i++)
            envelope(
              uid: i,
              subject: 'Aktif Arşiv İletisi $i',
              date: DateTime.utc(2026, 1, 1).add(Duration(days: i)),
            ),
          for (var i = 26; i <= 28; i++)
            envelope(
              uid: i,
              subject: 'Silinmiş Arşiv İletisi $i',
              date: DateTime.utc(2026, 1, 1).add(Duration(days: i)),
              extraFlags: [r'\Deleted'],
            ),
        ];
        imap.seedMailbox(archiveBox.path, envelopes);

        // Yerelde önceden 28 iletinin tamamı çekilmiş olsun
        for (final env in envelopes) {
          await db.into(db.messages).insert(
            MessagesCompanion.insert(
              accountId: accountId,
              mailboxId: archiveBox.id,
              uid: Value(env.uid),
              subject: Value(env.subject),
              dateUtc: env.date,
            ),
          );
        }
        expect(await db.countMessages(archiveBox.id), 28);

        // Mailbox'ın önceki durumu
        final currentBox = (await db.mailboxById(archiveBox.id))!.copyWith(
          totalCount: 28,
          uidNext: const Value(29),
        );
        await db.updateMailboxSync(
          archiveBox.id,
          totalCount: 28,
          uidNext: 29,
        );

        // Senkronizasyon çalıştırılır (reconcileMailbox undeletedOnly: true ile sorgular)
        final outcome = await sync.syncMailbox(
          accountId: accountId,
          mailbox: currentBox,
        );
        expect(outcome, isA<Ok<SyncOutcome>>());

        // 3 silinmiş iletinin temizlendiği ve yerel sayının 25'e indiği doğrulanır
        expect(await db.countMessages(archiveBox.id), 25);

        final remainingUids = await db.uidsOf(archiveBox.id);
        expect(remainingUids.length, 25);
        expect(remainingUids.contains(26), isFalse);
        expect(remainingUids.contains(27), isFalse);
        expect(remainingUids.contains(28), isFalse);
      },
    );

    test(
      'Arşiv klasöründe UIDsi olmayan yerel hayalet satırlar purgeGhostMessages ile koşulsuz temizlenir',
      () async {
        // 25 geçerli sunucu iletisi
        for (var i = 1; i <= 25; i++) {
          await db.into(db.messages).insert(
            MessagesCompanion.insert(
              accountId: accountId,
              mailboxId: archiveBox.id,
              uid: Value(i),
              subject: Value('Sunucu İletisi $i'),
              dateUtc: DateTime.utc(2026, 1, 1).add(Duration(days: i)),
            ),
          );
        }

        // 3 adet UID'si olmayan hayalet satır (örneğin mobilden kalmış veya yarım kalmış işlemler)
        for (var i = 1; i <= 3; i++) {
          await db.into(db.messages).insert(
            MessagesCompanion.insert(
              accountId: accountId,
              mailboxId: archiveBox.id,
              uid: const Value(null),
              isLocalOnly: const Value(true), // isLocalOnly true olsa bile temizlenmeli!
              subject: Value('Hayalet İleti $i'),
              dateUtc: DateTime.utc(2026, 1, 1),
            ),
          );
        }
        expect(await db.countMessages(archiveBox.id), 28);

        // purgeGhostMessages çalıştırılır
        await db.purgeGhostMessages(archiveBox.id);

        // Hayaletler silinmeli, geriye tam olarak 25 ileti kalmalı
        expect(await db.countMessages(archiveBox.id), 25);
      },
    );
  });
}
