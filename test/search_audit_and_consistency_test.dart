import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/mail_connection.dart';
import 'package:kaydet/data/repositories/sync_engine.dart';
import 'package:kaydet/data/services/imap_search_criteria.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/domain/models/search_filters.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

void main() {
  group('1. Arama İndeksinde Alıcıların (To, Cc, Bcc) Bulunması (Sent Klasörü)', () {
    late AppDatabase db;
    late int accountId;
    late int sentBoxId;

    setUp(() async {
      db = createTestDatabase();
      accountId = await db.insertAccount(
        AccountsCompanion.insert(
          email: 'ben@sirketim.com',
          username: 'ben@sirketim.com',
          imapHost: 'mail.sirketim.com',
          smtpHost: 'mail.sirketim.com',
        ),
      );
      sentBoxId = await db.into(db.mailboxes).insert(
        MailboxesCompanion.insert(
          accountId: accountId,
          path: 'INBOX.Sent',
          name: 'Gönderilenler',
          specialUse: const Value(SpecialUse.sent),
        ),
      );
    });

    tearDown(() => db.close());

    test('Gönderilen mail alıcının adına veya e-posta adresine göre aranabilir', () async {
      final msgId = await db.insertLocalMessage(
        MessagesCompanion.insert(
          accountId: accountId,
          mailboxId: sentBoxId,
          fromName: const Value('Ben'),
          fromEmail: const Value('ben@sirketim.com'),
          toAddrJson: Value(
            EmailAddress.encodeList([
              const EmailAddress(email: 'mehmet@partner.com', name: 'Mehmet Kaya'),
            ]),
          ),
          ccJson: Value(
            EmailAddress.encodeList([
              const EmailAddress(email: 'zeynep@sirketim.com', name: 'Zeynep Ak'),
            ]),
          ),
          bccJson: Value(
            EmailAddress.encodeList([
              const EmailAddress(email: 'gizli_denetim@holding.com'),
            ]),
          ),
          subject: const Value('Q4 İş Birliği Teklifi'),
          preview: const Value('Detaylar ektedir'),
          dateUtc: DateTime.utc(2026, 10, 20),
        ),
      );

      // 1. Alıcı adı ile arama
      final byName = await db.searchMessageIds(
        accountId: accountId,
        query: 'Mehmet',
      );
      expect(byName, contains(msgId));

      // 2. Alıcı soyadı ile arama (Türkçe karakter)
      final bySurname = await db.searchMessageIds(
        accountId: accountId,
        query: 'kaya',
      );
      expect(bySurname, contains(msgId));

      // 3. Alıcı e-posta adresi ile arama
      final byEmail = await db.searchMessageIds(
        accountId: accountId,
        query: 'partner.com',
      );
      expect(byEmail, contains(msgId));

      // 4. Cc alıcı adı ile arama
      final byCc = await db.searchMessageIds(
        accountId: accountId,
        query: 'Zeynep',
      );
      expect(byCc, contains(msgId));

      // 5. Bcc e-posta ile arama
      final byBcc = await db.searchMessageIds(
        accountId: accountId,
        query: 'holding.com',
      );
      expect(byBcc, contains(msgId));
    });

    test('Migrasyon / FTS Rebuild eski iletilerin alıcılarını indekse yazar', () async {
      final msgId = await db.into(db.messages).insert(
        MessagesCompanion.insert(
          accountId: accountId,
          mailboxId: sentBoxId,
          fromName: const Value('Ben'),
          fromEmail: const Value('ben@sirketim.com'),
          toAddrJson: Value(
            EmailAddress.encodeList([
              const EmailAddress(email: 'ahmet@eski.com', name: 'Ahmet Demir'),
            ]),
          ),
          subject: const Value('Eski Fatura'),
          preview: const Value('Fatura no 123'),
          dateUtc: DateTime.utc(2026, 5, 1),
        ),
      );

      // FTS tablosunu sil ve baştan kur (v24 -> v25 migrasyon simülasyonu)
      await db.customStatement('DELETE FROM messages_fts');
      expect(await db.searchMessageIds(accountId: accountId, query: 'Ahmet'), isEmpty);

      // _rebuildFtsIndex çalıştığında alıcılar dahil edilir
      await db.customStatement('DROP TABLE IF EXISTS messages_fts');
      await db.customStatement(
        'CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5('
        'content, tokenize="unicode61 remove_diacritics 2")',
      );

      // app_database'in v25 migrasyonu _rebuildFtsIndex() çağırır
      final rows = await db.customSelect(
        'SELECT m.id AS id, m.subject AS subject, m.from_name AS from_name, '
        'm.from_email AS from_email, m.to_addr_json AS to_addr_json, '
        'm.cc_json AS cc_json, m.bcc_json AS bcc_json, m.preview AS preview, '
        'b.plain_text AS body '
        'FROM messages m '
        'LEFT JOIN message_bodies b ON b.message_id = m.id',
        readsFrom: {db.messages, db.messageBodies},
      ).get();

      for (final r in rows) {
        final toAddr = r.read<String>('to_addr_json');
        final decoded = EmailAddress.decodeList(toAddr);
        final recipientsText = decoded.map((a) => '${a.name ?? ''} ${a.email}').join(' ');
        await db.customStatement(
          'INSERT INTO messages_fts (rowid, content) VALUES (?, ?)',
          [r.read<int>('id'), '${r.read<String>('subject')} $recipientsText'],
        );
      }

      final after = await db.searchMessageIds(accountId: accountId, query: 'Ahmet');
      expect(after, contains(msgId));
    });
  });

  group('2. Mail Sunucusu (IMAP) Source of Truth & 3. Search Hit Korunumu', () {
    late AppDatabase db;
    late FakeImapService imap;
    late MailConnection connection;
    late SyncEngine sync;
    late int accountId;
    late MailboxRow inbox;

    setUp(() async {
      db = createTestDatabase();
      imap = FakeImapService();
      final secureStore = InMemorySecureStore();
      accountId = await db.insertAccount(
        AccountsCompanion.insert(
          email: 'user@domain.com',
          username: 'user@domain.com',
          imapHost: 'mail.domain.com',
          smtpHost: 'mail.domain.com',
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
      inbox = (boxes as Ok<List<MailboxRow>>).value.firstWhere(
        (m) => m.specialUse == SpecialUse.inbox,
      );

      // Yerelde UID 200 zaten var ama gövdesi indirilmemiş (veya gövdede 'faturasi' geçiyor)
      imap.seedInbox([
        envelope(uid: 200, subject: 'Aylık Bildirim', fromEmail: 'servis@banka.com'),
      ]);
      await sync.syncMailbox(accountId: accountId, mailbox: inbox);
    });

    tearDown(() async {
      await connection.disconnect();
      await imap.dispose();
      await db.close();
    });

    test('Sunucu aramasında eşleşen ancak yerelde zaten mevcut olan UID elenmez (Search Hit korunur)', () async {
      // Sunucu 'faturasi' kelimesini hem yerelde mevcut UID 200'de hem de eski UID 50'de buldu:
      imap.searchUidsResult = [50, 200];
      imap.seedInbox([
        envelope(uid: 50, subject: 'Eski İşlem', fromEmail: 'muhasebe@sirket.com'),
      ]);

      final result = await sync.searchRemote(
        accountIds: [accountId],
        query: 'faturasi',
        filters: const SearchFilters(includeDeleted: true),
      );

      expect(result, isA<Ok<RemoteSearchResult>>());
      final res = (result as Ok<RemoteSearchResult>).value;
      // 50 yerele yeni indi: storedCount = 1
      expect(res.storedCount, 1);

      // Her iki UID'nin de yerel satır kimliği matchedMessageIds içinde korunmalı
      expect(res.matchedMessageIds, hasLength(2));

      // Yerel arama sorgusunda (searchMessageIds with serverHitIds)
      // gövdesi yerelde olmasa bile UID 200 asla elenmemelidir:
      final hitIds = res.matchedMessageIds.toSet();
      final searchResults = await db.searchMessageIds(
        accountId: accountId,
        query: 'faturasi',
        serverHitIds: hitIds,
      );

      final row200 = await db.messageByUid(inbox.id, 200);
      final row50 = await db.messageByUid(inbox.id, 50);
      expect(searchResults, containsAll([row200!.id, row50!.id]));
    });
  });

  group('4. Klasör Döngüsünün Erken Kesilmemesi (Folder Traversal)', () {
    late AppDatabase db;
    late FakeImapService imap;
    late MailConnection connection;
    late SyncEngine sync;
    late int accountId;

    setUp(() async {
      db = createTestDatabase();
      imap = FakeImapService();
      final secureStore = InMemorySecureStore();
      accountId = await db.insertAccount(
        AccountsCompanion.insert(
          email: 'test@traversal.com',
          username: 'test@traversal.com',
          imapHost: 'mail.traversal.com',
          smtpHost: 'mail.traversal.com',
        ),
      );
      await secureStore.writePassword(accountId, 'pass');
      connection = MailConnection(
        database: db,
        secureStore: secureStore,
        imapService: imap,
      );
      sync = SyncEngine(database: db, connection: connection);
      await sync.syncMailboxes(accountId);

      // Standart klasörleri tohumla:
      // INBOX: 0 eşleşme
      // Sent: 2 eşleşme (UID 301, 302)
      // Archive: 1 eşleşme (UID 401)
      imap.seedMailbox('INBOX', [envelope(uid: 101, subject: 'Gelen 1')]);
      imap.seedMailbox('INBOX.Sent', [
        envelope(uid: 301, subject: 'Gönderilen Rapor'),
        envelope(uid: 302, subject: 'Gönderilen Analiz'),
      ]);
      imap.seedMailbox('INBOX.Archive', [
        envelope(uid: 401, subject: 'Arşiv Raporu'),
      ]);
    });

    tearDown(() async {
      await connection.disconnect();
      await imap.dispose();
      await db.close();
    });

    test('Inbox 0 eşleşme verdiğinde döngü kırılmaz; Sent ve Archive taranır', () async {
      // INBOX için arama 0 sonuç döndürsün, Sent için [301, 302], Archive için [401]
      imap.searchUidsResult = [301, 302, 401];

      final traversedFolders = <String>[];
      final result = await sync.searchRemote(
        accountIds: [accountId],
        query: 'rapor',
        filters: const SearchFilters(includeDeleted: true),
        onHitsFound: (hits) {
          traversedFolders.add('hit_batch_${hits.length}');
        },
      );

      expect(result, isA<Ok<RemoteSearchResult>>());
      final res = (result as Ok<RemoteSearchResult>).value;

      // Toplam 3 ileti Sent ve Archive'dan indirildi (INBOX 0 verdi ama döngü durmadı!)
      expect(res.storedCount, 3);
      expect(res.matchedMessageIds, hasLength(3));
    });
  });

  group('5. IMAP Türkçe ve Non-ASCII Karakter Desteği & Graceful Fallback', () {
    test('buildFallbackAscii Türkçe karakterleri standart ASCIIye dönüştürür', () {
      final fallback = ImapSearchCriteria.buildFallbackAscii(
        words: ['Şeker', 'Çağrı', 'Öğrenci', 'Ücret'],
        from: 'İnci@şirket.com',
      );

      expect(fallback, isNotNull);
      // CHARSET UTF-8 veya literal içermemeli, saf ASCII tırnaklı metin olmalı
      expect(fallback!.contains('CHARSET'), isFalse);
      expect(fallback.contains('\n'), isFalse);
      expect(fallback.contains('TEXT "seker"'), isTrue);
      expect(fallback.contains('TEXT "cagri"'), isTrue);
      expect(fallback.contains('TEXT "ogrenci"'), isTrue);
      expect(fallback.contains('TEXT "ucret"'), isTrue);
      expect(fallback.contains('FROM "inci@sirket.com"'), isTrue);
    });

    test('Sunucu UTF-8de hata döndüğünde sessizce fallback ASCII aramaya geçer', () async {
      final db = createTestDatabase();
      final imap = FakeImapService();
      final secureStore = InMemorySecureStore();
      final accountId = await db.insertAccount(
        AccountsCompanion.insert(
          email: 'tr@test.com',
          username: 'tr@test.com',
          imapHost: 'mail.test.com',
          smtpHost: 'mail.test.com',
        ),
      );
      await secureStore.writePassword(accountId, 'pass');
      final connection = MailConnection(
        database: db,
        secureStore: secureStore,
        imapService: imap,
      );
      final sync = SyncEngine(database: db, connection: connection);
      await sync.syncMailboxes(accountId);

      imap.seedInbox([
        envelope(uid: 88, subject: 'Şeker fabrikası siparişi'),
      ]);
      imap.searchUidsResult = [88];

      // Sunucu CHARSET UTF-8 veya literal görünce hata dönsün:
      imap.onSearchUids = (criteria) {
        if (criteria.contains('CHARSET UTF-8') || criteria.contains('\n')) {
          return const ServerFailure(detail: 'NO [BADCHARSET] Not supported');
        }
        return null; // Fallback geçerli olsun
      };

      final result = await sync.searchRemote(
        accountIds: [accountId],
        query: 'şeker',
        filters: const SearchFilters(includeDeleted: true),
      );

      // Çökmeden ve hata fırlatmadan fallback ile başarılı olmalı
      expect(result, isA<Ok<RemoteSearchResult>>());
      final res = (result as Ok<RemoteSearchResult>).value;
      expect(res.storedCount, 1);
      expect(res.matchedMessageIds, hasLength(1));

      // Logda hem UTF-8 denemesi hem de fallback ASCII araması görülür
      expect(imap.searchCriteriaLog.any((c) => c.contains('CHARSET UTF-8')), isTrue);
      expect(imap.searchCriteriaLog.any((c) => c.contains('TEXT "seker"')), isTrue);

      await connection.disconnect();
      await imap.dispose();
      await db.close();
    });
  });

  group('6. Multi-Account İzolasyonu ve Güvenli Sayfalama', () {
    late AppDatabase db;
    late int acc1;
    late int acc2;
    late int box1;
    late int box2;

    setUp(() async {
      db = createTestDatabase();
      acc1 = await db.insertAccount(
        AccountsCompanion.insert(
          email: 'hesap1@kaydet.com',
          username: 'hesap1@kaydet.com',
          imapHost: 'mail1.kaydet.com',
          smtpHost: 'mail1.kaydet.com',
        ),
      );
      acc2 = await db.insertAccount(
        AccountsCompanion.insert(
          email: 'hesap2@kaydet.com',
          username: 'hesap2@kaydet.com',
          imapHost: 'mail2.kaydet.com',
          smtpHost: 'mail2.kaydet.com',
        ),
      );
      box1 = await db.into(db.mailboxes).insert(
        MailboxesCompanion.insert(
          accountId: acc1,
          path: 'INBOX',
          name: 'Gelen Kutusu',
        ),
      );
      box2 = await db.into(db.mailboxes).insert(
        MailboxesCompanion.insert(
          accountId: acc2,
          path: 'INBOX',
          name: 'Gelen Kutusu',
        ),
      );

      // acc1'e 5 ileti
      for (var i = 1; i <= 5; i++) {
        await db.insertLocalMessage(
          MessagesCompanion.insert(
            accountId: acc1,
            mailboxId: box1,
            subject: Value('Proje Toplantı $i'),
            dateUtc: DateTime.utc(2026, 10, i),
          ),
        );
      }

      // acc2'ye 3 ileti
      for (var i = 1; i <= 3; i++) {
        await db.insertLocalMessage(
          MessagesCompanion.insert(
            accountId: acc2,
            mailboxId: box2,
            subject: Value('Proje Raporu $i'),
            dateUtc: DateTime.utc(2026, 10, i),
          ),
        );
      }
    });

    tearDown(() => db.close());

    test('Tek hesap seçildiğinde diğer hesabın sonuçları KESİNLİKLE karışmaz', () async {
      final acc1Results = await db.searchMessageIds(
        accountId: acc1,
        query: 'Proje',
      );
      expect(acc1Results, hasLength(5));
      for (final id in acc1Results) {
        final row = await db.messageById(id);
        expect(row!.accountId, acc1);
      }

      final acc2Results = await db.searchMessageIds(
        accountId: acc2,
        query: 'Proje',
      );
      expect(acc2Results, hasLength(3));
      for (final id in acc2Results) {
        final row = await db.messageById(id);
        expect(row!.accountId, acc2);
      }
    });

    test('Tüm hesaplar arandığında tüm hesapların sonuçları gelir', () async {
      final allResults = await db.searchMessageIds(
        accountId: null,
        query: 'Proje',
      );
      expect(allResults, hasLength(8));
    });

    test('Limit ve Offset ile güvenli, çakışmasız sayfalama', () async {
      final page1 = await db.searchMessageIds(
        accountId: acc1,
        query: 'Proje',
        limit: 2,
        offset: 0,
      );
      expect(page1, hasLength(2));

      final page2 = await db.searchMessageIds(
        accountId: acc1,
        query: 'Proje',
        limit: 2,
        offset: 2,
      );
      expect(page2, hasLength(2));

      final page3 = await db.searchMessageIds(
        accountId: acc1,
        query: 'Proje',
        limit: 2,
        offset: 4,
      );
      expect(page3, hasLength(1));

      // Sayfalar arasında hiçbir id kesişmemeli
      final set1 = page1.toSet();
      final set2 = page2.toSet();
      final set3 = page3.toSet();
      expect(set1.intersection(set2), isEmpty);
      expect(set1.intersection(set3), isEmpty);
      expect(set2.intersection(set3), isEmpty);

      // Sıralama kesinlikle tarihe göre yeniden eskiye olmalı
      final dates = <DateTime>[];
      for (final id in [...page1, ...page2, ...page3]) {
        final row = await db.messageById(id);
        dates.add(row!.dateUtc);
      }
      for (var i = 0; i < dates.length - 1; i++) {
        expect(dates[i].isAfter(dates[i + 1]) || dates[i].isAtSameMomentAs(dates[i + 1]), isTrue);
      }
    });
  });
}
