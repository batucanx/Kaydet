import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/domain/models/mail_models.dart';

import 'helpers/test_db.dart';

void main() {
  late AppDatabase db;
  late int accountId;
  late int inboxId;

  setUp(() async {
    db = createTestDatabase();
    accountId = await db.insertAccount(
      AccountsCompanion.insert(
        email: 'info@pazarlik.com.tr',
        username: 'info@pazarlik.com.tr',
        imapHost: 'mail.pazarlik.com.tr',
        smtpHost: 'mail.pazarlik.com.tr',
        displayName: const Value('Pazarlık'),
      ),
    );
    inboxId = await db.upsertMailbox(
      MailboxesCompanion.insert(
        accountId: accountId,
        path: 'INBOX',
        name: 'Gelen Kutusu',
        specialUse: const Value(SpecialUse.inbox),
      ),
    );
  });

  tearDown(() => db.close());

  MessagesCompanion message({
    required int uid,
    String subject = 'Konu',
    String fromName = 'Ahmet Yılmaz',
    String fromEmail = 'ahmet@musteri.com',
    String preview = '',
    bool seen = false,
    bool flagged = false,
    DateTime? date,
  }) =>
      MessagesCompanion.insert(
        accountId: accountId,
        mailboxId: inboxId,
        dateUtc: date ?? DateTime.utc(2026, 9, 14, 10, 30),
        uid: Value(uid),
        subject: Value(subject),
        fromName: Value(fromName),
        fromEmail: Value(fromEmail),
        preview: Value(preview),
        isSeen: Value(seen),
        isFlagged: Value(flagged),
      );

  group('şema', () {
    test('hesap ve klasör yazılır', () async {
      final account = await db.activeAccount();
      expect(account, isNotNull);
      expect(account!.email, 'info@pazarlik.com.tr');
      expect(account.imapPort, 993);
      expect(account.imapSecurity, SocketSecurity.ssl);

      final inbox = await db.mailboxBySpecialUse(accountId, SpecialUse.inbox);
      expect(inbox?.path, 'INBOX');
    });

    test('deactivateAllAccounts ile aynı anda tek hesap etkin kalır',
        () async {
      final secondId = await db.insertAccount(
        AccountsCompanion.insert(
          email: 'ikinci@ornek.com',
          username: 'ikinci@ornek.com',
          imapHost: 'mail.ornek.com',
          smtpHost: 'mail.ornek.com',
        ),
      );

      // Hesap değiştirici modelinde geçiş her zaman "önce tümünü pasifleştir,
      // sonra hedefi etkinleştir" sırasıyla yapılır — aksi hâlde iki hesap
      // aynı anda `isActive=true` olabilir ve hangisinin gösterileceği
      // belirsizleşir.
      await db.deactivateAllAccounts();
      await db.updateAccountFields(
        secondId,
        const AccountsCompanion(isActive: Value(true)),
      );

      final active = await db.activeAccount();
      expect(active?.id, secondId);

      final all = await db.allAccounts();
      expect(all.where((a) => a.isActive), hasLength(1));
    });

    test('aynı UID iki kez yazılamaz — kısmi tekil indeks çalışır', () async {
      await db.upsertServerMessages([message(uid: 100)]);
      await db.upsertServerMessages([message(uid: 100, subject: 'Güncel')]);

      final rows = await db.watchMessages(
        accountId: accountId,
        mailboxId: inboxId,
      ).first;
      expect(rows, hasLength(1));
      expect(rows.single.subject, 'Güncel');
    });

    test('yerel iletiler uid olmadan yan yana durabilir', () async {
      await db.insertLocalMessage(
        MessagesCompanion.insert(
          accountId: accountId,
          mailboxId: inboxId,
          dateUtc: DateTime.utc(2026, 9, 14),
          isLocalOnly: const Value(true),
          subject: const Value('Taslak 1'),
        ),
      );
      await db.insertLocalMessage(
        MessagesCompanion.insert(
          accountId: accountId,
          mailboxId: inboxId,
          dateUtc: DateTime.utc(2026, 9, 14),
          isLocalOnly: const Value(true),
          subject: const Value('Taslak 2'),
        ),
      );
      expect(await db.countMessages(inboxId), 2);
    });

    test('hesap silinince iletiler de silinir (cascade)', () async {
      await db.upsertServerMessages([message(uid: 1), message(uid: 2)]);
      expect(await db.countMessages(inboxId), 2);
      await db.wipeAccount(accountId);
      expect(await db.countMessages(inboxId), 0);
    });
  });

  group('sayaçlar', () {
    test('okunmamış ve sabitlenmiş sayıları doğru', () async {
      await db.upsertServerMessages([
        message(uid: 1, seen: false),
        message(uid: 2, seen: true),
        message(uid: 3, seen: false, flagged: true),
      ]);
      expect(await db.countUnread(inboxId), 2);
      expect(await db.countFlagged(accountId), 1);
    });

    test('en düşük ve en yüksek UID bulunur', () async {
      await db.upsertServerMessages([
        message(uid: 42),
        message(uid: 7),
        message(uid: 99),
      ]);
      expect(await db.lowestUid(inboxId), 7);
      expect(await db.highestUid(inboxId), 99);
    });
  });

  group('tam metin arama (FTS5)', () {
    setUp(() async {
      await db.upsertServerMessages([
        message(
          uid: 1,
          subject: 'Fiyat Teklifi Revizesi',
          fromName: 'Haşem Şahan',
          fromEmail: 'hasem@barza.com',
          preview: 'Konuştuğumuz revizeleri ekte gönderiyorum',
        ),
        message(
          uid: 2,
          subject: 'Hesap Özeti',
          fromName: 'Banka Bildirim',
          fromEmail: 'noreply@banka.com',
          preview: 'Şubat ayı hesap özetiniz hazırdır',
        ),
        message(
          uid: 3,
          subject: 'Logo Çalışmaları',
          fromName: 'Zeynep Kaya',
          fromEmail: 'zeynep@tasarim.com',
          preview: 'Siyah beyaz konseptli taslaklar ektedir',
        ),
      ]);
    });

    test('konuya göre bulur', () async {
      final ids = await db.searchMessageIds(
        accountId: accountId,
        query: 'teklif',
      );
      expect(ids, hasLength(1));
      final row = await db.messageById(ids.single);
      expect(row!.subject, 'Fiyat Teklifi Revizesi');
    });

    test('Türkçe karakter katlaması: "sahan" → "Şahan"', () async {
      final ids = await db.searchMessageIds(
        accountId: accountId,
        query: 'sahan',
      );
      expect(ids, hasLength(1));
      expect((await db.messageById(ids.single))!.fromName, 'Haşem Şahan');
    });

    test('"ozet" araması "Özeti" bulur', () async {
      final ids = await db.searchMessageIds(
        accountId: accountId,
        query: 'ozet',
      );
      expect(ids, hasLength(1));
    });

    test('gönderen adresine göre bulur', () async {
      final ids = await db.searchMessageIds(
        accountId: accountId,
        query: 'tasarim.com',
      );
      expect(ids, isNotEmpty);
    });

    test('gövde indekslenince aranabilir olur', () async {
      final all = await db.watchMessages(
        accountId: accountId,
        mailboxId: inboxId,
      ).first;
      final target = all.firstWhere((m) => m.uid == 3);
      await db.upsertBody(
        messageId: target.id,
        plainText: 'Kurumsal kimlik çalışması için üç ayrı öneri hazırladık.',
      );

      final ids = await db.searchMessageIds(
        accountId: accountId,
        query: 'kurumsal',
      );
      expect(ids, contains(target.id));
    });

    test('FTS operatör karakterleri sorguyu çökertmez', () async {
      for (final query in ['"', '*', 'a AND', 'NEAR(', '-test', '((']) {
        final ids = await db.searchMessageIds(
          accountId: accountId,
          query: query,
        );
        expect(ids, isA<List<int>>(), reason: 'sorgu: $query');
      }
    });

    test('silinen ileti arama indeksinden de çıkar', () async {
      final ids = await db.searchMessageIds(
        accountId: accountId,
        query: 'teklif',
      );
      await db.deleteMessages(ids);
      final after = await db.searchMessageIds(
        accountId: accountId,
        query: 'teklif',
      );
      expect(after, isEmpty);
    });
  });

  group('UIDVALIDITY temizliği', () {
    test('sunucu iletileri silinir, yerel taslak korunur', () async {
      await db.upsertServerMessages([message(uid: 1), message(uid: 2)]);
      await db.insertLocalMessage(
        MessagesCompanion.insert(
          accountId: accountId,
          mailboxId: inboxId,
          dateUtc: DateTime.utc(2026, 9, 14),
          isLocalOnly: const Value(true),
          subject: const Value('Yazılmamış taslak'),
        ),
      );

      await db.purgeMailboxMessages(inboxId);

      final remaining = await db.watchMessages(
        accountId: accountId,
        mailboxId: inboxId,
      ).first;
      expect(remaining, hasLength(1));
      expect(remaining.single.subject, 'Yazılmamış taslak');
    });
  });

  group('bekleyen işlem kuyruğu', () {
    test('sıraya alınır ve zamanı gelenler döner', () async {
      await db.enqueue(
        PendingOperationsCompanion.insert(
          accountId: accountId,
          type: PendingOpType.markSeen,
          payloadJson: const Value('{"uids":[1,2]}'),
        ),
      );
      await db.enqueue(
        PendingOperationsCompanion.insert(
          accountId: accountId,
          type: PendingOpType.flag,
          nextAttemptAt: Value(
            DateTime.now().toUtc().add(const Duration(hours: 1)),
          ),
        ),
      );

      final due = await db.dueOperations(accountId);
      expect(due, hasLength(1));
      expect(due.single.type, PendingOpType.markSeen);
    });

    test('kalıcı hata kuyruktan çıkarır', () async {
      final id = await db.enqueue(
        PendingOperationsCompanion.insert(
          accountId: accountId,
          type: PendingOpType.send,
        ),
      );
      await db.failOperation(
        id,
        error: 'alıcı reddedildi',
        attemptCount: 1,
        permanent: true,
      );
      expect(await db.dueOperations(accountId), isEmpty);
    });
  });

  group('gövde önbelleği', () {
    test('eski gövdeler budanır, envelope kalır', () async {
      await db.upsertServerMessages([message(uid: 1)]);
      final row = (await db.watchMessages(
        accountId: accountId,
        mailboxId: inboxId,
      ).first)
          .single;

      await db.upsertBody(messageId: row.id, plainText: 'içerik');
      expect(await db.bodyOf(row.id), isNotNull);

      // 60 gün geriye alınmış bir gövde.
      await db.customStatement(
        'UPDATE message_bodies SET fetched_at = ? WHERE message_id = ?',
        [
          DateTime.now()
                  .toUtc()
                  .subtract(const Duration(days: 60))
                  .millisecondsSinceEpoch ~/
              1000,
          row.id,
        ],
      );

      final pruned = await db.pruneOldBodies();
      expect(pruned, 1);
      expect(await db.bodyOf(row.id), isNull);
      expect(await db.messageById(row.id), isNotNull);
    });
  });
}
