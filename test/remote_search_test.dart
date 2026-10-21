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

/// Sunucu araması: yerelde olmayan (eski) iletiler IMAP `SEARCH` ile bulunup
/// "arama sonucu" olarak yazılır ve klasör listelerine/sayaçlara/eşitleme
/// sınırlarına KATILMAZ.
void main() {
  group('ImapSearchCriteria', () {
    test('sözcükler TEXT, gönderen FROM, alıcı üç alanda aranır', () {
      expect(
        ImapSearchCriteria.build(
          words: ['fatura', 'mart'],
          from: 'ali@firma.com',
          recipient: 'ece@firma.com',
        ),
        'TEXT "fatura" TEXT "mart" FROM "ali@firma.com" '
        'OR OR TO "ece@firma.com" CC "ece@firma.com" BCC "ece@firma.com" '
        'UNDELETED',
      );
    });

    test('tarihler IMAP biçimindedir (gün sıfırsız, İngilizce ay)', () {
      expect(
        ImapSearchCriteria.build(
          since: DateTime(2026, 10, 5),
          before: DateTime(2026, 12, 1),
        ),
        'SINCE 5-Oct-2026 BEFORE 1-Dec-2026 UNDELETED',
      );
    });

    test('tırnak ve ters eğik çizgi kaçırılır, ölçüt enjekte edilemez', () {
      expect(
        ImapSearchCriteria.build(words: [r'a"b\c) ALL']),
        r'TEXT "a\"b\\c) ALL" UNDELETED',
      );
    });

    test('ASCII dışı sözcük CHARSET UTF-8 ve literal olarak gider', () {
      // "Haşem": ş iki bayt → 6 bayt.
      expect(
        ImapSearchCriteria.build(words: ['Haşem']),
        'CHARSET UTF-8 TEXT {6}\nHaşem UNDELETED',
      );
    });

    test('hiçbir koşul yoksa null döner', () {
      expect(ImapSearchCriteria.build(), isNull);
      expect(ImapSearchCriteria.build(words: ['  ']), isNull);
    });
  });

  test(
    'remoteSearchWords adresi korur, tekrarları atar, 5 sözcükle sınırlar',
    () {
      expect(
        SyncEngine.remoteSearchWords('Fatura fatura, ali@firma.com (mart)'),
        ['Fatura', 'ali@firma.com', 'mart'],
      );
      expect(SyncEngine.remoteSearchWords('  ... '), isEmpty);
      expect(SyncEngine.remoteSearchWords('a b c d e f g'), hasLength(5));
    },
  );

  group('SyncEngine.searchRemote', () {
    late AppDatabase db;
    late FakeImapService imap;
    late MailConnection connection;
    late SyncEngine sync;
    late int accountId;
    late MailboxRow inbox;

    const filters = SearchFilters(includeDeleted: true);

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
      final boxes = await sync.syncMailboxes(accountId);
      inbox = (boxes as Ok<List<MailboxRow>>).value.firstWhere(
        (m) => m.specialUse == SpecialUse.inbox,
      );

      // Yerel kopya: UID 100 ve 101 (pencere). Sunucuda ayrıca çok eski UID 5
      // ve yeni gelmiş UID 900 var.
      imap.seedInbox([envelope(uid: 100), envelope(uid: 101)]);
      await sync.syncMailbox(accountId: accountId, mailbox: inbox);
      imap.seedInbox([
        envelope(
          uid: 5,
          subject: 'Eski sözleşme',
          fromEmail: 'ali@firma.com',
          date: DateTime.utc(2020, 1, 2),
        ),
        envelope(uid: 900, subject: 'Yeni sözleşme', seen: false),
      ]);
    });

    tearDown(() async {
      await connection.disconnect();
      await imap.dispose();
      await db.close();
    });

    Future<int> search(String query, [SearchFilters f = filters]) async {
      final result = await sync.searchRemote(
        accountIds: [accountId],
        query: query,
        filters: f,
      );
      return (result as Ok<int>).value;
    }

    test(
      'yerelde olmayan eski ileti bulunur ve yerel aramada görünür',
      () async {
        imap.searchUidsResult = [5, 100, 900];

        // 100 yerelde zaten var; yalnızca 5 ve 900 indirilir.
        expect(await search('sozlesme'), 2);
        // Her klasör aynı ölçütle aranır.
        expect(imap.searchCriteriaLog.toSet(), {'TEXT "sozlesme" UNDELETED'});

        final ids = await db.searchMessageIds(
          accountId: accountId,
          query: 'sözleşme',
          filters: filters,
        );
        final subjects = [
          for (final id in ids) (await db.messageById(id))!.subject,
        ];
        // Tarihe göre yeniden eskiye.
        expect(subjects, ['Yeni sözleşme', 'Eski sözleşme']);
      },
    );

    test(
      'gövdede eşleşen sonuç, konuda geçmese de yerel aramada görünür',
      () async {
        imap.seedInbox([envelope(uid: 7, subject: 'Konu başka')]);
        imap.searchUidsResult = [7];

        expect(await search('teklifname'), 1);

        final ids = await db.searchMessageIds(
          accountId: accountId,
          query: 'teklifname',
          filters: filters,
        );
        expect(ids, hasLength(1));
      },
    );

    test(
      'arama sonuçları klasör listesine, sayaca ve UID sınırlarına katılmaz',
      () async {
        final unreadBefore = await db.countUnread(inbox.id);
        imap.searchUidsResult = [5, 900];
        await search('sozlesme');

        expect(await db.uidsOf(inbox.id), containsAll([5, 900, 100, 101]));
        // Eşitleme sınırları yalnızca gerçek pencereden hesaplanır: "daha eski
        // yükle" 5'e inmiş sanmaz, artımlı eşitleme 900'ü atlamaz.
        expect(await db.lowestUid(inbox.id), 100);
        expect(await db.highestUid(inbox.id), 101);
        expect(await db.countMessages(inbox.id), 2);
        expect(await db.countUnread(inbox.id), unreadBefore);

        final listed = await db
            .watchMessages(accountId: accountId, mailboxId: inbox.id)
            .first;
        expect(listed.map((m) => m.uid), unorderedEquals([100, 101]));
      },
    );

    test('aynı arama ikinci kez yeni ileti yazmaz', () async {
      imap.searchUidsResult = [5, 900];
      expect(await search('sozlesme'), 2);
      expect(await search('sozlesme'), 0);
    });

    test('normal eşitleme arama sonucunu olağan iletiye çevirir', () async {
      imap.searchUidsResult = [900];
      await search('sozlesme');
      expect(await db.highestUid(inbox.id), 101);

      await sync.syncMailbox(
        accountId: accountId,
        mailbox: (await db.mailboxById(inbox.id))!,
      );

      expect(await db.highestUid(inbox.id), 900);
      final row = (await db.messageByUid(inbox.id, 900))!;
      expect(row.isSearchHit, isFalse);
    });

    test('gönderen filtresi metin olmadan da sunucuda aranır', () async {
      imap.searchUidsResult = [5];

      expect(
        await search(
          '',
          const SearchFilters(includeDeleted: true, sender: 'ali@firma.com'),
        ),
        1,
      );
      expect(imap.searchCriteriaLog.toSet(), {
        'FROM "ali@firma.com" UNDELETED',
      });
    });

    test('metin, gönderen, alıcı ve tarih yoksa sunucuya gidilmez', () async {
      imap.searchUidsResult = [5];

      expect(await search(''), 0);
      imap.searchCriteriaLog.clear();
      expect(
        await search(
          '',
          const SearchFilters(
            includeDeleted: true,
            withAttachmentsOnly: true,
            folder: SearchFolder.standard(SpecialUse.inbox),
          ),
        ),
        0,
      );
      expect(imap.searchCriteriaLog, isEmpty);
    });

    test('"Ekli" yalnızca eki olan sonuçları yazar', () async {
      imap.seedInbox([
        envelope(uid: 11, subject: 'Rapor ekli').copyWithAttachments(true),
        envelope(uid: 12, subject: 'Rapor ekisiz'),
      ]);
      imap.searchUidsResult = [11, 12];

      expect(
        await search(
          'rapor',
          const SearchFilters(includeDeleted: true, withAttachmentsOnly: true),
        ),
        1,
      );
    });

    test('ters tarih penceresi sunucuya gitmeden boş döner', () async {
      expect(
        await search(
          'sozlesme',
          SearchFilters(
            includeDeleted: true,
            dateFrom: DateTime(2026, 10, 12),
            dateTo: DateTime(2026, 10, 1),
          ),
        ),
        0,
      );
      expect(imap.searchCriteriaLog, isEmpty);
    });

    test('hiçbir klasör aranamazsa hata döner', () async {
      await connection.disconnect();
      imap.failOnConnect = const ConnectionFailure();
      final result = await sync.searchRemote(
        accountIds: [accountId],
        query: 'sozlesme',
        filters: filters,
      );
      expect(result, isA<Err<int>>());
    });

    test(
      'arama sonuçları hesap başına sınırlanır (en eskiler silinir)',
      () async {
        imap.searchUidsResult = [5, 900];
        await search('sozlesme');

        await db.pruneSearchHits(accountId, keep: 1);

        final left = await db.uidsOf(inbox.id);
        // Yeni olan kalır, en eski sonuç silinir; olağan iletilere dokunulmaz.
        expect(left, unorderedEquals([100, 101, 900]));
      },
    );
  });
}

extension on FetchedEnvelope {
  FetchedEnvelope copyWithAttachments(bool value) => FetchedEnvelope(
    uid: uid,
    date: date,
    subject: subject,
    from: from,
    to: to,
    cc: cc,
    bcc: bcc,
    flags: flags,
    sizeBytes: sizeBytes,
    hasAttachments: value,
    messageId: messageId,
    references: references,
  );
}
