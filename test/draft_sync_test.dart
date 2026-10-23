import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/draft_repository_impl.dart';
import 'package:kaydet/data/repositories/mail_connection.dart';
import 'package:kaydet/data/repositories/mail_repository.dart';
import 'package:kaydet/data/repositories/sync_engine.dart';
import 'package:kaydet/data/services/draft_remote_data_source.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/domain/repositories/draft_repository.dart';
import 'package:kaydet/domain/use_cases/save_draft_use_case.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

void main() {
  late AppDatabase db;
  late FakeImapService imap;
  late FakeSmtpService smtp;
  late InMemorySecureStore secureStore;
  late MailConnection connection;
  late SyncEngine sync;
  late DraftRemoteDataSource draftRemoteSource;
  late DraftRepository draftRepo;
  late SaveDraftUseCase saveDraftUseCase;
  late MailRepository mailRepo;

  late int accountId;
  late MailboxRow draftsMailbox;

  Future<MailboxRow> freshDraftsBox() async =>
      (await db.mailboxById(draftsMailbox.id))!;

  Future<SyncOutcome> syncDrafts() async {
    final result = await sync.syncMailbox(
      accountId: accountId,
      mailbox: await freshDraftsBox(),
    );
    return (result as Ok<SyncOutcome>).value;
  }

  Future<List<MessageRow>> getDraftMessages() async =>
      (db.select(db.messages)
            ..where((m) => m.mailboxId.equals(draftsMailbox.id))
            ..orderBy([(m) => OrderingTerm(expression: m.id)]))
          .get();

  setUp(() async {
    db = createTestDatabase();
    imap = FakeImapService();
    smtp = FakeSmtpService();
    secureStore = InMemorySecureStore();

    accountId = await db.insertAccount(
      AccountsCompanion.insert(
        email: 'user@kaydet.app',
        username: 'user@kaydet.app',
        imapHost: 'mail.kaydet.app',
        smtpHost: 'mail.kaydet.app',
      ),
    );
    await secureStore.writePassword(accountId, 'secret');

    connection = MailConnection(
      database: db,
      secureStore: secureStore,
      imapService: imap,
    );
    sync = SyncEngine(database: db, connection: connection);
    draftRemoteSource = ImapDraftRemoteDataSource(connection);
    draftRepo = DraftRepositoryImpl(
      database: db,
      remoteDataSource: draftRemoteSource,
      connection: connection,
      syncEngine: sync,
    );
    saveDraftUseCase = SaveDraftUseCase(draftRepo);
    mailRepo = MailRepository(
      database: db,
      connection: connection,
      syncEngine: sync,
      smtpService: smtp,
      draftRepository: draftRepo,
    );

    final mailboxes = await sync.syncMailboxes(accountId);
    draftsMailbox = (mailboxes as Ok<List<MailboxRow>>).value.firstWhere(
      (m) => m.specialUse == SpecialUse.drafts,
    );
  });

  tearDown(() async {
    await connection.disconnect();
    await imap.dispose();
    await db.close();
  });

  group('Server-Side Draft Sync (Senaryo 1: Web -> Mobile)', () {
    test('Webte olusturulan taslak IMAP uzerinden mobile sync edilir ve goruntulenir', () async {
      // 1. Web client IMAP Drafts klasörüne taslak ekler
      final draftBox = imap.store['INBOX.Drafts'] ??= {};
      draftBox[101] = FetchedEnvelope(
        uid: 101,
        date: DateTime.utc(2026, 10, 14, 10, 0),
        subject: 'Web Taslagi',
        from: const EmailAddress(email: 'user@kaydet.app'),
        to: const [EmailAddress(email: 'alici@example.com')],
        cc: const [],
        bcc: const [],
        flags: const [r'\Draft'],
        sizeBytes: 256,
        hasAttachments: false,
        messageId: '<web-msg-101@kaydet.app>',
      );
      imap.seedBody(
        'INBOX.Drafts',
        101,
        const FetchedBody(
          plainText: 'Webte hazirlanan taslak govdesi',
          html: '<p>Webte hazirlanan taslak govdesi</p>',
        ),
      );

      // 2. Mobil sync calisir
      final outcome = await syncDrafts();
      expect(outcome.newMessageIds.length, 1);

      // 3. Drift veritabanında taslak kontrol edilir
      final drafts = await getDraftMessages();
      expect(drafts.length, 1);
      final draft = drafts.first;
      expect(draft.uid, 101);
      expect(draft.subject, 'Web Taslagi');
      expect(draft.isDraft, isTrue);
      expect(draft.messageIdHeader, 'web-msg-101@kaydet.app');

      // 4. Govde yukleme use-case/repo cagrildiginda govde doldurulur
      final loadRes = await draftRepo.ensureDraftBodyLoaded(draft.id);
      expect(loadRes.isOk, isTrue);
      final body = await db.bodyOf(draft.id);
      expect(body, isNotNull);
      expect(body!.plainText, 'Webte hazirlanan taslak govdesi');
      expect(body.html, '<p>Webte hazirlanan taslak govdesi</p>');
    });
  });

  group('Server-Side Draft Sync (Senaryo 2: Mobile -> IMAP / Web)', () {
    test('Mobilde kaydedilen taslak Drift ve IMAP Draftsa kaydedilir', () async {
      final draftId = await draftRepo.saveDraftLocal(
        accountId: accountId,
        subject: 'Mobil Yeni Taslak',
        body: 'Mobilden merhaba',
        html: '<p>Mobilden merhaba</p>',
        to: 'musteri@pazarlik.com.tr',
        cc: '',
        bcc: '',
      );
      expect(draftId, greaterThan(0));

      // Drift'e ilk kayıtta henüz serverUid yoktur ve isLocalOnly=true
      var localRow = (await db.messageById(draftId))!;
      expect(localRow.isDraft, isTrue);
      expect(localRow.isLocalOnly, isTrue);
      expect(localRow.subject, 'Mobil Yeni Taslak');
      expect(localRow.messageIdHeader, isNotNull);

      // Remote sync çağrısı IMAP Drafts'a APPEND eder
      final syncRes = await draftRepo.syncDraftRemote(draftId);
      expect(syncRes.isOk, isTrue);

      // Drift güncellenmiştir (uid atanmış, isLocalOnly false yapılmıştır)
      localRow = (await db.messageById(draftId))!;
      expect(localRow.uid, isNotNull);
      expect(localRow.isLocalOnly, isFalse);
      final serverUid = localRow.uid!;

      // IMAP'te taslak var mı kontrol edilir
      final imapDrafts = imap.store['INBOX.Drafts']!;
      expect(imapDrafts.containsKey(serverUid), isTrue);
      expect(imapDrafts[serverUid]!.subject, 'Mobil Yeni Taslak');
      expect(imapDrafts[serverUid]!.flags, contains(r'\Draft'));
    });
  });

  group('Server-Side Draft Sync (Senaryo 3: Web Edits -> Mobile Sync)', () {
    test('Webte duzenlenen taslak mobilde ayni kayit uzerinde guncellenir (duplicate yok)', () async {
      const sharedMessageId = '<draft-shared-guid-1@kaydet.app>';

      // 1. Ilk surum hem mobilde hem sunucuda UID 200 olarak var
      final draftBox = imap.store['INBOX.Drafts'] ??= {};
      draftBox[200] = FetchedEnvelope(
        uid: 200,
        date: DateTime.utc(2026, 10, 14, 10, 0),
        subject: 'Ilk Baslik',
        from: const EmailAddress(email: 'user@kaydet.app'),
        to: const [EmailAddress(email: 'alici@example.com')],
        cc: const [],
        bcc: const [],
        flags: const [r'\Draft'],
        sizeBytes: 120,
        hasAttachments: false,
        messageId: sharedMessageId,
      );
      await syncDrafts();

      var drafts = await getDraftMessages();
      expect(drafts.length, 1);
      final originalId = drafts.first.id;
      expect(drafts.first.uid, 200);

      // 2. Web taslagi duzenler: IMAPte UID 200 silinir, UID 205 olarak yeni surum olusur
      draftBox.remove(200);
      draftBox[205] = FetchedEnvelope(
        uid: 205,
        date: DateTime.utc(2026, 10, 14, 10, 5),
        subject: 'Web Tarafindan Guncellendi',
        from: const EmailAddress(email: 'user@kaydet.app'),
        to: const [EmailAddress(email: 'alici@example.com')],
        cc: const [],
        bcc: const [],
        flags: const [r'\Draft'],
        sizeBytes: 150,
        hasAttachments: false,
        messageId: sharedMessageId,
      );

      // 3. Mobile sync calisir
      await syncDrafts();

      // 4. Driftte DUPLICATE olmamali! Ayni messageIdHeader ile UID 205 guncellenmeli
      drafts = await getDraftMessages();
      expect(drafts.length, 1, reason: 'Duplicate olmamali, tek taslak kalmali');
      expect(drafts.first.id, originalId);
      expect(drafts.first.uid, 205);
      expect(drafts.first.subject, 'Web Tarafindan Guncellendi');
    });
  });

  group('Server-Side Draft Sync (Senaryo 4: Mobile Edits -> IMAP Updated, Old UID Expunged)', () {
    test('Mobilde var olan taslak duzenlendiginde eski IMAP UID silinir ve tek taslak kalir', () async {
      // 1. Taslak olustur ve sync et
      final draftId = await draftRepo.saveDraftLocal(
        accountId: accountId,
        subject: 'Taslak v1',
        body: 'v1 icerik',
        to: 'test@example.com',
        cc: '',
        bcc: '',
      );
      await draftRepo.syncDraftRemote(draftId);

      var row = (await db.messageById(draftId))!;
      final uid1 = row.uid!;
      expect(imap.store['INBOX.Drafts']!.containsKey(uid1), isTrue);

      // 2. Kullanici mobilde ayni taslagi degistirir
      await draftRepo.saveDraftLocal(
        accountId: accountId,
        draftId: draftId,
        subject: 'Taslak v2 Guncel',
        body: 'v2 guncel icerik',
        to: 'test@example.com',
        cc: '',
        bcc: '',
      );

      // 3. Remote sync calisir
      final syncRes = await draftRepo.syncDraftRemote(draftId);
      expect(syncRes.isOk, isTrue);

      row = (await db.messageById(draftId))!;
      final uid2 = row.uid!;
      expect(uid2, isNot(uid1));

      // 4. IMAP Drafts klasorunde ESKI UID SILINMIS OLMALI, sadece YENI UID kalmali!
      final imapDrafts = imap.store['INBOX.Drafts']!;
      expect(imapDrafts.containsKey(uid1), isFalse, reason: 'Eski UID silinmeli');
      expect(imapDrafts.containsKey(uid2), isTrue);
      expect(imapDrafts[uid2]!.subject, 'Taslak v2 Guncel');
      expect(imapDrafts.length, 1, reason: 'IMAPte duplicate draft olmamali');
    });

    test('Arka arkaya hizli kayitlarda (autosave) lock sayesinde duplicate olusmaz', () async {
      final draftId = await draftRepo.saveDraftLocal(
        accountId: accountId,
        subject: 'Hizli Autosave v1',
        body: 'ilk metin',
        to: 'test@example.com',
        cc: '',
        bcc: '',
      );

      // 2 kez pes pese sync tetikle
      final future1 = draftRepo.syncDraftRemote(draftId);
      final future2 = draftRepo.syncDraftRemote(draftId);

      await Future.wait([future1, future2]);

      final imapDrafts = imap.store['INBOX.Drafts']!;
      expect(imapDrafts.length, 1, reason: 'Mutex lock sayesinde duplicate engellenir');
    });
  });

  group('Offline-first & Pending Sync', () {
    test('Offline iken kaydedilen taslak online olunca sync edilir ve pending op temizlenir', () async {
      // 1. Cihaz offline
      imap.failOnConnect = const ConnectionFailure(detail: 'Internet yok');
      await connection.disconnect();

      final draftId = await saveDraftUseCase(
        accountId: accountId,
        subject: 'Offline Taslak',
        body: 'Internetsiz yazildi',
        to: 'hedef@pazarlik.com.tr',
        cc: '',
        bcc: '',
      );

      // syncDraftRemote'un offline hata durumunda pending op oluşturmasını garantile
      await draftRepo.syncDraftRemote(draftId);

      // Driftte olustu ama serverUid yok
      var localRow = (await db.messageById(draftId))!;
      expect(localRow.uid, isNull);
      expect(localRow.isLocalOnly, isTrue);

      // Pending operation kuyruğuna girdi mi?
      final pendingOps = await db.pendingDraftOperationsFor(draftId);
      expect(pendingOps.length, 1);
      expect(pendingOps.first.type, PendingOpType.appendDraft);

      // 2. Cihaz online oldu
      imap.failOnConnect = null;

      // Pending queue islenir
      await mailRepo.processQueue(accountId);
      await mailRepo.waitForQueue();

      // 3. Pending op temizlenmis ve local taslak serverUid almis olmali
      final pendingAfter = await db.pendingDraftOperationsFor(draftId);
      expect(pendingAfter, isEmpty);

      localRow = (await db.messageById(draftId))!;
      expect(localRow.uid, isNotNull);
      expect(localRow.isLocalOnly, isFalse);

      final imapDrafts = imap.store['INBOX.Drafts']!;
      expect(imapDrafts.containsKey(localRow.uid), isTrue);
      expect(imapDrafts[localRow.uid]!.subject, 'Offline Taslak');
    });
  });

  group('Draft Send Cleanup', () {
    test('Taslak gonderildiginde basarili SMTP sonrasi IMAP Draftstan ve yerelden temizlenir', () async {
      // 1. Taslagi kaydet ve sync et
      final draftId = await draftRepo.saveDraftLocal(
        accountId: accountId,
        subject: 'Gonderilecek Taslak',
        body: 'Son surum metin',
        to: 'alici@pazarlik.com.tr',
        cc: '',
        bcc: '',
      );
      await draftRepo.syncDraftRemote(draftId);

      final row = (await db.messageById(draftId))!;
      final serverUid = row.uid!;
      expect(imap.store['INBOX.Drafts']!.containsKey(serverUid), isTrue);

      // 2. Gonderime kuyrukla (undoDelay: Duration.zero hemen isletir)
      final queueRes = await mailRepo.queueSend(
        accountId: accountId,
        draftId: draftId,
        to: 'alici@pazarlik.com.tr',
        cc: '',
        bcc: '',
        subject: 'Gonderilecek Taslak',
        body: 'Son surum metin',
        undoDelay: Duration.zero,
      );
      expect(queueRes, greaterThan(0));

      // 3. Kuyrugu isle (SMTP basarili)
      await mailRepo.processQueue(accountId);
      await mailRepo.waitForQueue();
      expect(smtp.sent.length, 1);

      // 4. IMAP Drafts klasöründen taslak kaldirilmis olmali!
      expect(
        imap.store['INBOX.Drafts']!.containsKey(serverUid),
        isFalse,
        reason: 'Gonderilen taslak IMAP Drafts klasorunden expunge edilmeli',
      );
    });

    test('SMTP basarisiz olursa taslak IMAP Draftstan silinmez', () async {
      // 1. Taslagi kaydet ve sync et
      final draftId = await draftRepo.saveDraftLocal(
        accountId: accountId,
        subject: 'Hata Alacak Taslak',
        body: 'Metin',
        to: 'alici@pazarlik.com.tr',
        cc: '',
        bcc: '',
      );
      await draftRepo.syncDraftRemote(draftId);

      final row = (await db.messageById(draftId))!;
      final serverUid = row.uid!;

      // 2. SMTP hata versin
      smtp.failOnSend = const ConnectionFailure(detail: 'SMTP sunucu baglanti hatasi');

      await mailRepo.queueSend(
        accountId: accountId,
        draftId: draftId,
        to: 'alici@pazarlik.com.tr',
        cc: '',
        bcc: '',
        subject: 'Hata Alacak Taslak',
        body: 'Metin',
        undoDelay: Duration.zero,
      );

      await mailRepo.processQueue(accountId);
      await mailRepo.waitForQueue();
      expect(smtp.sent, isEmpty);

      // 3. IMAP Draftsta taslak HÂLÂ durmali
      expect(
        imap.store['INBOX.Drafts']!.containsKey(serverUid),
        isTrue,
        reason: 'SMTP hatasinda taslak kaybolmamali',
      );
    });
  });

  group('Server Delete Reconciliation', () {
    test('Sunucuda silinen taslak mobile sync edildiginde Drift veritabanindan da silinir', () async {
      // 1. Sunucuda 300 UIDli taslak var
      final draftBox = imap.store['INBOX.Drafts'] ??= {};
      draftBox[300] = FetchedEnvelope(
        uid: 300,
        date: DateTime.utc(2026, 10, 14, 10, 0),
        subject: 'Silinecek Taslak',
        from: const EmailAddress(email: 'user@kaydet.app'),
        to: const [EmailAddress(email: 'b@example.com')],
        cc: const [],
        bcc: const [],
        flags: const [r'\Draft'],
        sizeBytes: 100,
        hasAttachments: false,
        messageId: '<del-300@kaydet.app>',
      );
      await syncDrafts();

      expect(await db.uidsOf(draftsMailbox.id), contains(300));

      // 2. Web/sunucu tarafindan taslak silindi
      draftBox.remove(300);

      // 3. Mobil sync calisir
      await syncDrafts();

      // 4. Driftte de taslak kalmamali
      expect(await db.uidsOf(draftsMailbox.id), isNot(contains(300)));
    });

    test('Sunucuda 9 taslak varken (ayni Message-ID paylassalar bile) mobilde tam 9 taslak gorunur', () async {
      final draftBox = imap.store['INBOX.Drafts'] ??= {};
      draftBox.clear();

      // 9 adet taslak sunucuya eklenir (bazi taslaklar ayni messageId paylassin)
      for (var i = 1; i <= 9; i++) {
        draftBox[500 + i] = FetchedEnvelope(
          uid: 500 + i,
          date: DateTime.utc(2026, 10, 14, 10, i),
          subject: 'Taslak $i',
          from: const EmailAddress(email: 'user@kaydet.app'),
          to: const [EmailAddress(email: 'alici@example.com')],
          cc: const [],
          bcc: const [],
          flags: const [r'\Draft'],
          sizeBytes: 100 + i,
          hasAttachments: false,
          // 8. ve 9. taslak ayni messageId paylasiyor (ornegin ayni maile yanit verilmis iki taslak)
          messageId: i >= 8 ? '<shared-thread-draft@kaydet.app>' : '<draft-$i@kaydet.app>',
        );
      }

      await syncDrafts();

      final drafts = await getDraftMessages();
      expect(drafts.length, 9, reason: 'Sunucudaki 9 taslagin tamami mobilde bulunmali');
      final uids = await db.uidsOf(draftsMailbox.id);
      expect(uids.length, 9);
      for (var i = 1; i <= 9; i++) {
        expect(uids.contains(500 + i), isTrue);
      }
    });
  });
}
