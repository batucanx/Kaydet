import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/mail_log.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/mail_connection.dart';
import 'package:kaydet/data/repositories/mail_repository.dart';
import 'package:kaydet/data/repositories/sync_engine.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/domain/models/mail_models.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

/// Sunucu tek gerçek kaynaktır, Drift yalnızca önbellektir: kullanıcı
/// eylemleri sunucuya işlenir ve ekran sunucudan geri okunan durumu gösterir.
void main() {
  late AppDatabase db;
  late FakeImapService imap;
  late FakeSmtpService smtp;
  late MailConnection connection;
  late SyncEngine sync;
  late MailRepository repository;
  late int accountId;
  late List<String> logLines;

  Future<MailboxRow> box(SpecialUse use) async =>
      (await db.mailboxBySpecialUse(accountId, use))!;

  Future<List<MessageRow>> rowsOf(int mailboxId) => (db.select(
    db.messages,
  )..where((m) => m.mailboxId.equals(mailboxId))).get();

  /// Eylemin kendi tetiklediği (kickQueue) turu da bekler.
  Future<void> drainQueue() async {
    await repository.waitForQueue();
    await repository.processQueue(accountId);
    await repository.waitForQueue();
  }

  Future<void> syncBox(SpecialUse use) async {
    final result = await sync.syncMailbox(
      accountId: accountId,
      mailbox: await box(use),
    );
    expect(result, isA<Ok<SyncOutcome>>());
  }

  Future<void> bootstrapMailboxes() async {
    final result = await sync.syncMailboxes(accountId);
    expect(result, isA<Ok<List<MailboxRow>>>());
  }

  setUp(() async {
    logLines = [];
    MailLog.sink = logLines.add;
    db = createTestDatabase();
    imap = FakeImapService();
    smtp = FakeSmtpService();
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
      smtpService: smtp,
    );
  });

  tearDown(() async {
    MailLog.sink = null;
    await connection.disconnect();
    await imap.dispose();
    await db.close();
  });

  test('silme: ileti sunucuda Çöp Kutusu\'na taşınır ve yerel Çöp Kutusu '
      'sunucudan okunur', () async {
    imap.seedInbox([envelope(uid: 1, subject: 'Silinecek')]);
    await bootstrapMailboxes();
    await syncBox(SpecialUse.inbox);

    final rows = await rowsOf((await box(SpecialUse.inbox)).id);
    await repository.deleteMessages([rows.single.id]);
    await drainQueue();

    // Sunucu: Gelen Kutusu boş, Çöp Kutusu'nda ileti var.
    expect(imap.store['INBOX'], isEmpty);
    expect(imap.store['INBOX.Trash'], hasLength(1));

    // Yerel: kaynak klasör boş; Çöp Kutusu, eşitleme beklenmeden sunucudaki
    // gerçek UID ile dolu (yerel tahmin değil).
    final trashId = (await box(SpecialUse.trash)).id;
    expect(await db.uidsOf((await box(SpecialUse.inbox)).id), isEmpty);
    expect(await db.uidsOf(trashId), imap.store['INBOX.Trash']!.keys.toList());
    expect(
      logLines.any((l) => l.startsWith('[RECONCILIATION] INBOX.Trash')),
      isTrue,
      reason: '$logLines',
    );
  });

  test('sunucuda başarısız silme yerelde "silindi" olarak kalmaz', () async {
    imap.seedInbox([envelope(uid: 1, subject: 'Silinecek')]);
    await bootstrapMailboxes();
    await syncBox(SpecialUse.inbox);
    final inboxId = (await box(SpecialUse.inbox)).id;

    imap.failMove = const ServerFailure(detail: 'NO', isPermanent: true);
    final rows = await rowsOf(inboxId);
    await repository.deleteMessages([rows.single.id]);
    await drainQueue();

    // Sunucu iletiyi taşımadı → sunucudan geri yüklenir, Trash'te kayıt yok.
    expect(imap.store['INBOX'], hasLength(1));
    expect(await db.uidsOf(inboxId), [1]);
    expect(await db.uidsOf((await box(SpecialUse.trash)).id), isEmpty);
  });

  test(
    'harici istemcide Çöp Kutusu\'na taşınan ileti eşitlemeyle düşer',
    () async {
      imap.seedInbox([envelope(uid: 1), envelope(uid: 2, subject: 'Diğer')]);
      await bootstrapMailboxes();
      await syncBox(SpecialUse.inbox);

      // Başka bir istemci uid 1'i Çöp Kutusu'na taşıdı.
      final moved = imap.store['INBOX']!.remove(1)!;
      imap.store.putIfAbsent('INBOX.Trash', () => {})[1] = moved;

      await syncBox(SpecialUse.inbox);
      await syncBox(SpecialUse.trash);

      expect(await db.uidsOf((await box(SpecialUse.inbox)).id), [2]);
      expect(await db.uidsOf((await box(SpecialUse.trash)).id), [1]);
    },
  );

  test('gönderim: SMTP sonrası kopya sunucu Gönderilenler\'ine yazılır ve '
      'eşitleme kopya üretmez', () async {
    await bootstrapMailboxes();
    await syncBox(SpecialUse.inbox);

    final id = await repository.queueSend(
      accountId: accountId,
      to: 'musteri@firma.com',
      cc: '',
      bcc: '',
      subject: 'Teklif',
      body: 'Merhaba',
      undoDelay: null,
    );
    await drainQueue();

    expect(smtp.sent, hasLength(1));
    // Sunucu gerçekten kopyayı tutuyor.
    expect(imap.store['INBOX.Sent'], hasLength(1));
    final serverUid = imap.store['INBOX.Sent']!.keys.single;

    // Yerel satır sunucudaki UID'ye bağlandı.
    final row = (await db.messageById(id))!;
    expect(row.uid, serverUid);
    expect(row.isLocalOnly, isFalse);

    // Sent klasörü eşitlenince aynı ileti ikinci kez eklenmez.
    final sentId = (await box(SpecialUse.sent)).id;
    await syncBox(SpecialUse.sent);
    await syncBox(SpecialUse.sent);
    expect(await db.uidsOf(sentId), [serverUid]);
    expect(await db.countMessages(sentId), 1);
  });

  group('gönderim onayı', () {
    Future<int> send() => repository.queueSend(
      accountId: accountId,
      to: 'musteri@firma.com',
      cc: '',
      bcc: '',
      subject: 'Teklif',
      body: 'Merhaba',
      undoDelay: null,
    );

    Future<List<PendingOperationRow>> verifyOps() => (db.select(
      db.pendingOperations,
    )..where((p) => p.type.equalsValue(PendingOpType.verifySent))).get();

    /// Bekleyen işlemleri hemen yürütülecek hâle getirir (geri çekilmeyi atlar).
    Future<void> makeDue() => db
        .update(db.pendingOperations)
        .write(
          PendingOperationsCompanion(
            nextAttemptAt: Value(
              DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
            ),
          ),
        );

    setUp(() async {
      await bootstrapMailboxes();
      await syncBox(SpecialUse.inbox);
    });

    test('SMTP kabulü ve Gönderilenler doğrulaması kaydedilir', () async {
      final id = await send();
      await drainQueue();

      final row = (await db.messageById(id))!;
      expect(row.outboxState, OutboxState.sent);
      expect(row.smtpAcceptedAt, isNotNull);
      expect(row.smtpReply, startsWith('250'));
      expect(row.sentVerifiedAt, isNotNull);
      expect(await verifyOps(), isEmpty);
    });

    test('SMTP başarısızsa kabul/doğrulama bilgisi yazılmaz', () async {
      smtp.failOnSend = const ConnectionFailure();
      final id = await send();
      await drainQueue();

      final row = (await db.messageById(id))!;
      expect(row.outboxState, isNot(OutboxState.sent));
      expect(row.smtpAcceptedAt, isNull);
      expect(row.sentVerifiedAt, isNull);
    });

    test('doğrulama sorgusu hata verirse işlem kuyruğa alınır ve sonra '
        'başarılı olur', () async {
      imap.failExistsByMessageId = const ConnectionFailure();
      final id = await send();
      await drainQueue();

      var row = (await db.messageById(id))!;
      expect(row.outboxState, OutboxState.sent);
      expect(row.smtpAcceptedAt, isNotNull);
      expect(row.sentVerifiedAt, isNull);
      expect(await verifyOps(), hasLength(1));

      imap.failExistsByMessageId = null;
      await makeDue();
      await drainQueue();

      row = (await db.messageById(id))!;
      expect(row.sentVerifiedAt, isNotNull);
      expect(await verifyOps(), isEmpty);
    });

    test(
      '3 denemeden sonra vazgeçilir; ileti sent kalır, hata yazılmaz',
      () async {
        imap.failExistsByMessageId = const ConnectionFailure();
        final id = await send();
        await drainQueue();

        for (var i = 0; i < 3; i++) {
          await makeDue();
          await drainQueue();
        }

        final row = (await db.messageById(id))!;
        expect(row.outboxState, OutboxState.sent);
        expect(row.outboxError, isNull);
        expect(row.sentVerifiedAt, isNull);
        expect(await verifyOps(), isEmpty);
      },
    );

    Future<void> deliverBounce(
      String source, {
      int uid = 50,
      String fromEmail = 'MAILER-DAEMON@mail.pazarlik.com.tr',
      String subject = 'Undelivered Mail Returned to Sender',
    }) async {
      imap.store.putIfAbsent('INBOX', () => {})[uid] = envelope(
        uid: uid,
        subject: subject,
        fromName: 'Mail Delivery System',
        fromEmail: fromEmail,
        date: DateTime.now().toUtc(),
        messageId: 'bounce-$uid@test',
      );
      imap.rawSources.putIfAbsent('INBOX', () => {})[uid] = source;
      await syncBox(SpecialUse.inbox);
    }

    String bounceFor(String messageId, {String action = 'failed'}) =>
        'Final-Recipient: rfc822; yok@firma.com\n'
        'Action: $action\n'
        'Status: ${action == 'failed' ? '5.1.1' : '4.4.1'}\n'
        'Diagnostic-Code: smtp; 550 5.1.1 User unknown\n\n'
        'Message-ID: <$messageId>\n';

    int rawFetches() =>
        imap.commandLog.where((c) => c.startsWith('raw:')).length;

    test('iade iletisi gelince teslim hatası ve nedeni yazılır', () async {
      final id = await send();
      await drainQueue();
      final messageId = (await db.messageById(id))!.messageIdHeader!;
      expect((await db.messageById(id))!.deliveryFailedAt, isNull);

      await deliverBounce(bounceFor(messageId));
      expect(await repository.detectBounces(accountId), 1);

      final row = (await db.messageById(id))!;
      expect(row.deliveryFailedAt, isNotNull);
      expect(row.deliveryFailureReason, contains('Alıcı adresi bulunamadı'));
      expect(row.deliveryFailureReason, contains('yok@firma.com'));
      // Gönderim durumu değişmez; uygulama iletiyi "gönderilmedi" yapmaz.
      expect(row.outboxState, OutboxState.sent);
    });

    test('başka bir iletiye ait iade, bu iletiyi işaretlemez ve yeniden '
        'indirilmez', () async {
      final id = await send();
      await drainQueue();

      await deliverBounce(bounceFor('baska-ileti@test'));
      expect(await repository.detectBounces(accountId), 0);
      expect(await repository.detectBounces(accountId), 0);

      expect((await db.messageById(id))!.deliveryFailedAt, isNull);
      expect(rawFetches(), 1);
    });

    test('gecikme bildirimi teslim hatası sayılmaz', () async {
      final id = await send();
      await drainQueue();
      final messageId = (await db.messageById(id))!.messageIdHeader!;

      await deliverBounce(
        bounceFor(messageId, action: 'delayed'),
        subject: 'Delivery Status Notification (Delay)',
      );
      expect(await repository.detectBounces(accountId), 0);
      expect((await db.messageById(id))!.deliveryFailedAt, isNull);
    });

    test('iade gibi görünmeyen gelen ileti indirilmez', () async {
      await send();
      await drainQueue();

      imap.store['INBOX']![60] = envelope(
        uid: 60,
        subject: 'Teklif hakkında',
        date: DateTime.now().toUtc(),
      );
      await syncBox(SpecialUse.inbox);
      expect(await repository.detectBounces(accountId), 0);
      expect(rawFetches(), 0);
    });

    test(
      'APPEND başarısızsa doğrulama, kopya sonra yazılınca yapılır',
      () async {
        imap.failAppend = const ConnectionFailure();
        final id = await send();
        await drainQueue();

        var row = (await db.messageById(id))!;
        expect(row.outboxState, OutboxState.sent);
        expect(row.smtpAcceptedAt, isNotNull);
        expect(row.sentVerifiedAt, isNull);
        expect(smtp.sent, hasLength(1));

        imap.failAppend = null;
        await makeDue();
        await drainQueue();

        row = (await db.messageById(id))!;
        expect(row.sentVerifiedAt, isNotNull);
        // Yeniden gönderim yapılmadı.
        expect(smtp.sent, hasLength(1));
      },
    );
  });

  test('gönderim: sunucuda Gönderilenler yoksa oluşturulur, ileti '
      'saklanmadan "tamam" sayılmaz', () async {
    imap.mailboxes.removeWhere((m) => m.specialUse == SpecialUse.sent);
    await bootstrapMailboxes();
    expect(await db.mailboxBySpecialUse(accountId, SpecialUse.sent), isNull);

    await repository.queueSend(
      accountId: accountId,
      to: 'musteri@firma.com',
      cc: '',
      bcc: '',
      subject: 'Teklif',
      body: 'Merhaba',
      undoDelay: null,
    );
    await drainQueue();

    expect(smtp.sent, hasLength(1));
    expect(imap.commandLog.where((c) => c.startsWith('create:')), isNotEmpty);
    final sentPath = imap.mailboxes
        .firstWhere((m) => m.path.toLowerCase().endsWith('sent'))
        .path;
    expect(imap.store[sentPath], hasLength(1));
  });

  test('ASCII olmayan klasöre taşıma kodlanmış yolla sunucuya gider', () async {
    imap.mailboxes.add(
      const RemoteMailbox(
        path: 'INBOX.Çöp',
        encodedPath: 'INBOX.&AOcA9g-p',
        name: 'Çöp',
        delimiter: '.',
        specialUse: SpecialUse.custom,
      ),
    );
    imap.seedInbox([envelope(uid: 1)]);
    await bootstrapMailboxes();
    await syncBox(SpecialUse.inbox);

    final target = (await db.mailboxesOf(
      accountId,
    )).firstWhere((m) => m.path == 'INBOX.Çöp');
    expect(target.encodedPath, 'INBOX.&AOcA9g-p');

    final rows = await rowsOf((await box(SpecialUse.inbox)).id);
    await repository.moveToFolder(
      messageIds: [rows.single.id],
      targetMailboxId: target.id,
    );
    await drainQueue();

    expect(imap.moveEncodedPaths.single.target, 'INBOX.&AOcA9g-p');
  });
}
