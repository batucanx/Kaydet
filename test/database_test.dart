import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/domain/models/search_filters.dart';

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
    bool hasAttachments = false,
    bool draft = false,
    bool deleted = false,
    int? mailbox,
    DateTime? date,
  }) =>
      MessagesCompanion.insert(
        accountId: accountId,
        mailboxId: mailbox ?? inboxId,
        dateUtc: date ?? DateTime.utc(2026, 9, 14, 10, 30),
        uid: Value(uid),
        subject: Value(subject),
        fromName: Value(fromName),
        fromEmail: Value(fromEmail),
        preview: Value(preview),
        isSeen: Value(seen),
        isFlagged: Value(flagged),
        hasAttachments: Value(hasAttachments),
        isDraft: Value(draft),
        isDeleted: Value(deleted),
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

    test('tüm hesapların okunmamış toplamını izler', () async {
      final secondAccountId = await db.insertAccount(
        AccountsCompanion.insert(
          email: 'ikinci@ornek.com',
          username: 'ikinci@ornek.com',
          imapHost: 'mail.ornek.com',
          smtpHost: 'mail.ornek.com',
        ),
      );
      final secondInboxId = await db.upsertMailbox(
        MailboxesCompanion.insert(
          accountId: secondAccountId,
          path: 'INBOX',
          name: 'Gelen Kutusu',
          specialUse: const Value(SpecialUse.inbox),
        ),
      );

      await db.upsertServerMessages([
        message(uid: 10),
        message(uid: 11),
        message(uid: 12, seen: true),
        message(uid: 13, deleted: true),
        MessagesCompanion.insert(
          accountId: secondAccountId,
          mailboxId: secondInboxId,
          dateUtc: DateTime.utc(2026, 9, 14),
          uid: const Value(20),
        ),
      ]);

      expect(await db.watchAllUnreadCount().first, 3);
      final messages = await db
          .watchMessages(accountId: secondAccountId, mailboxId: secondInboxId)
          .first;
      await db.updateMessage(
        messages.single.id,
        const MessagesCompanion(isSeen: Value(true)),
      );
      expect(await db.watchAllUnreadCount().first, 2);
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

  group('arama: sıralama ve filtreler', () {
    late int trashId;
    late int draftsId;
    late int workId;

    setUp(() async {
      trashId = await db.upsertMailbox(
        MailboxesCompanion.insert(
          accountId: accountId,
          path: 'Trash',
          name: 'Çöp Kutusu',
          specialUse: const Value(SpecialUse.trash),
        ),
      );
      draftsId = await db.upsertMailbox(
        MailboxesCompanion.insert(
          accountId: accountId,
          path: 'Drafts',
          name: 'Taslaklar',
          specialUse: const Value(SpecialUse.drafts),
        ),
      );
      // Özel klasör: `specialUse` varsayılanı `custom`.
      workId = await db.upsertMailbox(
        MailboxesCompanion.insert(
          accountId: accountId,
          path: 'Work',
          name: 'Work',
        ),
      );
    });

    Future<List<String>> subjectsOf(List<int> ids) async => [
      for (final id in ids) (await db.messageById(id))!.subject,
    ];

    test('sonuçlar tarihe göre yeniden eskiye gelir', () async {
      await db.upsertServerMessages([
        message(uid: 1, subject: 'Rapor eski', date: DateTime.utc(2026, 1, 10)),
        message(uid: 2, subject: 'Rapor yeni', date: DateTime.utc(2026, 9, 10)),
        message(uid: 3, subject: 'Rapor orta', date: DateTime.utc(2026, 5, 10)),
      ]);

      final ids = await db.searchMessageIds(
        accountId: accountId,
        query: 'rapor',
      );

      expect(await subjectsOf(ids), ['Rapor yeni', 'Rapor orta', 'Rapor eski']);
    });

    test('sınır, en yeni sonuçları korur', () async {
      await db.upsertServerMessages([
        for (var day = 1; day <= 5; day++)
          message(
            uid: day,
            subject: 'Bülten $day',
            date: DateTime.utc(2026, 1, day),
          ),
      ]);

      final ids = await db.searchMessageIds(
        accountId: accountId,
        query: 'bulten',
        limit: 2,
      );

      expect(await subjectsOf(ids), ['Bülten 5', 'Bülten 4']);
    });

    test('"Ekleri Var" yalnızca ekli iletileri getirir', () async {
      await db.upsertServerMessages([
        message(uid: 1, subject: 'Fatura ekli', hasAttachments: true),
        message(uid: 2, subject: 'Fatura eksiz'),
      ]);

      final ids = await db.searchMessageIds(
        accountId: accountId,
        query: 'fatura',
        filters: const SearchFilters(withAttachmentsOnly: true),
      );

      expect(await subjectsOf(ids), ['Fatura ekli']);
    });

    test('Çöp Kutusu varsayılan olarak dışarıda kalır, '
        '"silinmiş öğeler" ile gelir', () async {
      await db.upsertServerMessages([
        message(uid: 1, subject: 'Sözleşme gelen'),
        message(uid: 2, subject: 'Sözleşme silinmiş', mailbox: trashId),
      ]);

      final withoutTrash = await db.searchMessageIds(
        accountId: accountId,
        query: 'sozlesme',
      );
      final withTrash = await db.searchMessageIds(
        accountId: accountId,
        query: 'sozlesme',
        filters: const SearchFilters(includeDeleted: true),
      );

      expect(await subjectsOf(withoutTrash), ['Sözleşme gelen']);
      expect(withTrash, hasLength(2));
    });

    test('standart klasör filtresi yalnızca o klasörü kapsar', () async {
      await db.upsertServerMessages([
        message(uid: 1, subject: 'Toplantı notu'),
        message(
          uid: 2,
          subject: 'Toplantı taslağı',
          mailbox: draftsId,
          draft: true,
        ),
      ]);

      final ids = await db.searchMessageIds(
        accountId: accountId,
        query: 'toplanti',
        filters: const SearchFilters(
          folder: SearchFolder.standard(SpecialUse.drafts),
        ),
      );

      expect(await subjectsOf(ids), ['Toplantı taslağı']);
      expect((await db.messageById(ids.single))!.isDraft, isTrue);
    });

    test('özel klasör ada göre eşleşir', () async {
      await db.upsertServerMessages([
        message(uid: 1, subject: 'Proje planı'),
        message(uid: 2, subject: 'Proje bütçesi', mailbox: workId),
      ]);

      final ids = await db.searchMessageIds(
        accountId: accountId,
        query: 'proje',
        filters: const SearchFilters(folder: SearchFolder.custom('Work')),
      );

      expect(await subjectsOf(ids), ['Proje bütçesi']);
    });

    test('Çöp Kutusu açıkça seçilirse "silinmiş öğeler" kapalıyken de '
        'aranır', () async {
      await db.upsertServerMessages([
        message(uid: 1, subject: 'Anlaşma gelen'),
        message(uid: 2, subject: 'Anlaşma silinmiş', mailbox: trashId),
      ]);

      final ids = await db.searchMessageIds(
        accountId: accountId,
        query: 'anlasma',
        filters: const SearchFilters(
          folder: SearchFolder.standard(SpecialUse.trash),
        ),
      );

      expect(await subjectsOf(ids), ['Anlaşma silinmiş']);
    });

    test(r'`\Deleted` bayraklı iletiler hiçbir durumda çıkmaz', () async {
      await db.upsertServerMessages([
        message(uid: 1, subject: 'Duyuru aktif'),
        message(uid: 2, subject: 'Duyuru silinecek', deleted: true),
      ]);

      final ids = await db.searchMessageIds(
        accountId: accountId,
        query: 'duyuru',
        filters: const SearchFilters(includeDeleted: true),
      );

      expect(await subjectsOf(ids), ['Duyuru aktif']);
    });

    test('dosya araması klasör ve silinmiş öğe filtrelerine uyar', () async {
      final ids = await db.upsertServerMessages([
        message(uid: 1, subject: 'Ek gelen', hasAttachments: true),
        message(
          uid: 2,
          subject: 'Ek silinmiş',
          hasAttachments: true,
          mailbox: trashId,
        ),
      ]);
      for (final id in ids) {
        await db.addAttachment(
          AttachmentsCompanion.insert(
            messageId: id,
            fileName: const Value('sozlesme.pdf'),
          ),
        );
      }

      Future<int> fileCount(SearchFilters filters) async => (await db
              .searchAttachments(
                accountId: accountId,
                query: 'sozlesme',
                filters: filters,
              ))
          .length;

      expect(await fileCount(const SearchFilters()), 1);
      expect(await fileCount(const SearchFilters(includeDeleted: true)), 2);
      expect(
        await fileCount(
          const SearchFilters(folder: SearchFolder.standard(SpecialUse.trash)),
        ),
        1,
      );
    });

    test('klasör listesi seçilebilir klasörleri döner', () async {
      final options = await db.selectableMailboxes(accountId: accountId);

      expect(
        options.map((m) => m.specialUse),
        unorderedEquals([
          SpecialUse.inbox,
          SpecialUse.trash,
          SpecialUse.drafts,
          SpecialUse.custom,
        ]),
      );
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
    test('sıraya alınır ve zamanı gelenler sahiplenilir', () async {
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

      final due = await db.claimDueOperations(accountId);
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
      expect(await db.claimDueOperations(accountId), isEmpty);
    });

    test('aynı işlem iki kez sahiplenilemez (çift-işlem koruması)', () async {
      await db.enqueue(
        PendingOperationsCompanion.insert(
          accountId: accountId,
          type: PendingOpType.markSeen,
        ),
      );

      final first = await db.claimDueOperations(accountId);
      expect(first, hasLength(1));

      // Kira henüz dolmadı — ikinci bir sahiplenme denemesi boş dönmeli.
      final second = await db.claimDueOperations(accountId);
      expect(second, isEmpty);
    });

    test(
      'geri çekilmede bekleyen ESKİ işlemler, zamanı gelmiş DAHA YENİ '
      'işlemlerin sahiplenilmesini engellemez (aday penceresi tıkanmaz)',
      () async {
        // `limit` varsayılanı (50) kadar eski işlem, tamamı geri çekilmede
        // (backoff) — aday penceresini dolduracak sayıda.
        for (var i = 0; i < 50; i++) {
          await db.enqueue(
            PendingOperationsCompanion.insert(
              accountId: accountId,
              type: PendingOpType.flag,
              nextAttemptAt: Value(
                DateTime.now().toUtc().add(const Duration(hours: 1)),
              ),
            ),
          );
        }
        // Sonradan eklenen ve zamanı ÇOKTAN gelmiş tek bir işlem.
        await db.enqueue(
          PendingOperationsCompanion.insert(
            accountId: accountId,
            type: PendingOpType.markSeen,
          ),
        );

        final claimed = await db.claimDueOperations(accountId);
        expect(claimed, hasLength(1));
        expect(claimed.single.type, PendingOpType.markSeen);
      },
    );

    test('renewLease yalnızca running durumundaki işlemi tazeler', () async {
      final id = await db.enqueue(
        PendingOperationsCompanion.insert(
          accountId: accountId,
          type: PendingOpType.markSeen,
        ),
      );
      final claimed = await db.claimDueOperations(accountId);
      expect(claimed, hasLength(1));

      await db.renewLease(id);
      final activeAfterRenew = await db.activeOperations(accountId);
      expect(
        activeAfterRenew.single.nextAttemptAt!.isAfter(
          DateTime.now().toUtc().add(const Duration(minutes: 2)),
        ),
        isTrue,
      );

      // `pending` bir işlem için (hiç sahiplenilmemiş) renewLease sessizce
      // hiçbir şeyi değiştirmemeli.
      final pendingId = await db.enqueue(
        PendingOperationsCompanion.insert(
          accountId: accountId,
          type: PendingOpType.flag,
        ),
      );
      await db.renewLease(pendingId);
      final stillPending = await db.activeOperations(accountId);
      final pendingRow = stillPending.firstWhere((p) => p.id == pendingId);
      expect(pendingRow.status, PendingOpStatus.pending);
      expect(pendingRow.nextAttemptAt, isNull);
    });

    test('releaseOperations denemesiz şekilde pending\'e döndürür', () async {
      await db.enqueue(
        PendingOperationsCompanion.insert(
          accountId: accountId,
          type: PendingOpType.markSeen,
        ),
      );
      final claimed = await db.claimDueOperations(accountId);
      expect(claimed, hasLength(1));

      await db.releaseOperations([claimed.single.id]);
      final released = await db.activeOperations(accountId);
      expect(released.single.status, PendingOpStatus.pending);
      expect(released.single.nextAttemptAt, isNull);
      expect(released.single.attemptCount, 0);
    });
  });

  group('giden kutusu sahiplenme (claimOutboxSend)', () {
    test('taze sahiplenme "sending" durumundaki iletiyi yeniden almaz', () async {
      final messageId = await db.insertLocalMessage(message(uid: 1));

      final firstClaim = await db.claimOutboxSend(
        messageId,
        allowReclaim: false,
      );
      expect(firstClaim, 1);

      // İkinci bir işlemci aynı iletiyi TAZE bir sahiplenmeyle (kira dolmadı)
      // tekrar göndermeye çalışırsa reddedilmeli — aksi hâlde alıcı aynı
      // e-postayı iki kez alır.
      final secondClaim = await db.claimOutboxSend(
        messageId,
        allowReclaim: false,
      );
      expect(secondClaim, 0);
    });

    test(
      'yalnızca kira dolmuş bir yeniden-sahiplenmede "sending" kurtarılabilir',
      () async {
        final messageId = await db.insertLocalMessage(message(uid: 1));

        await db.claimOutboxSend(messageId, allowReclaim: false);
        // Kira dolmuş bir yeniden sahiplenmeyi simüle eder.
        final reclaimed = await db.claimOutboxSend(
          messageId,
          allowReclaim: true,
        );
        expect(reclaimed, 1);
      },
    );

    test('"sent" durumundaki ileti hiçbir zaman yeniden sahiplenilmez', () async {
      final messageId = await db.insertLocalMessage(message(uid: 1));
      await db.updateMessage(
        messageId,
        const MessagesCompanion(outboxState: Value(OutboxState.sent)),
      );

      expect(await db.claimOutboxSend(messageId, allowReclaim: false), 0);
      expect(await db.claimOutboxSend(messageId, allowReclaim: true), 0);
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
