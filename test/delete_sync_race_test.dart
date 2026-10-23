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

/// Swipe ile silinen ileti, sunucu işlemi uygulanmadan (geri-alma penceresi,
/// çevrimdışı, geri çekilme) yapılan HİÇBİR eşitleme yolunda yerele geri
/// yazılmamalı — "silinen ileti kısa süre geri gelip kaybolur" hatasının
/// regresyon testi.
void main() {
  late AppDatabase db;
  late FakeImapService imap;
  late MailConnection connection;
  late SyncEngine sync;
  late MailRepository repository;
  late int accountId;

  const undoWindow = Duration(seconds: 6);

  Future<MailboxRow> box(SpecialUse use) async =>
      (await db.mailboxBySpecialUse(accountId, use))!;

  Future<List<int>> localUids(SpecialUse use) async =>
      (await db.uidsOf((await box(use)).id))..sort();

  Future<MessageRow> rowOfUid(int uid) async =>
      (await db.messageByUid((await box(SpecialUse.inbox)).id, uid))!;

  Future<void> drainQueue() async {
    await repository.waitForQueue();
    await repository.processQueue(accountId);
    await repository.waitForQueue();
  }

  Future<void> syncInbox({bool forceReconcile = false}) async {
    final result = await sync.syncMailbox(
      accountId: accountId,
      mailbox: await box(SpecialUse.inbox),
      forceReconcile: forceReconcile,
    );
    expect(result, isA<Ok<SyncOutcome>>());
  }

  /// Geri-alma penceresini doldurulmuş sayar: bekleyen işlem hemen çalışır.
  Future<void> expireUndoWindow() => (db.update(
    db.pendingOperations,
  )).write(const PendingOperationsCompanion(nextAttemptAt: Value(null)));

  setUp(() async {
    MailLog.sink = (_) {};
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
    MailLog.sink = null;
    await connection.disconnect();
    await imap.dispose();
    await db.close();
  });

  Future<void> seed(List<int> uids) async {
    imap.seedInbox([for (final uid in uids) envelope(uid: uid)]);
    expect(await sync.syncMailboxes(accountId), isA<Ok<List<MailboxRow>>>());
    await syncInbox();
    expect(await localUids(SpecialUse.inbox), uids);
  }

  test('geri-alma penceresinde yenileme silinen iletiyi geri getirmez', () async {
    await seed([1, 2, 3]);

    await repository.deleteMessages([
      (await rowOfUid(2)).id,
    ], undoWindow: undoWindow);
    expect(await localUids(SpecialUse.inbox), [1, 3]);
    // Sunucu işlemi henüz uygulanmadı: ileti sunucuda duruyor.
    expect(imap.store['INBOX']!.keys, contains(2));

    await syncInbox();
    expect(await localUids(SpecialUse.inbox), [1, 3]);

    // Aşağı çekerek yenileme (tam uzlaşma) da aynı sonucu vermeli.
    await syncInbox(forceReconcile: true);
    expect(await localUids(SpecialUse.inbox), [1, 3]);

    // İşlem uygulanır, ardından yeniden eşitlenir: ileti hiç görünmemiştir.
    await expireUndoWindow();
    await drainQueue();
    expect(imap.store['INBOX']!.keys, isNot(contains(2)));
    expect(imap.store['INBOX.Trash'], hasLength(1));
    await syncInbox(forceReconcile: true);
    expect(await localUids(SpecialUse.inbox), [1, 3]);
  });

  test('en yeni (en yüksek UID) ileti silinince artımlı eşitleme onu geri '
      'çekmez', () async {
    await seed([1, 2, 3]);

    await repository.deleteMessages([
      (await rowOfUid(3)).id,
    ], undoWindow: undoWindow);

    await syncInbox();
    expect(await localUids(SpecialUse.inbox), [1, 2]);
    await syncInbox(forceReconcile: true);
    expect(await localUids(SpecialUse.inbox), [1, 2]);
  });

  test('klasördeki tek ileti silinince ilk-indirme yolu onu geri çekmez', () async {
    await seed([7]);

    await repository.deleteMessages([
      (await rowOfUid(7)).id,
    ], undoWindow: undoWindow);

    await syncInbox();
    expect(await localUids(SpecialUse.inbox), isEmpty);
    await syncInbox(forceReconcile: true);
    expect(await localUids(SpecialUse.inbox), isEmpty);
  });

  test('art arda çok sayıda silme (200 üstü) hiçbir iletiyi geri getirmez', () async {
    final uids = List.generate(230, (i) => i + 1);
    imap.seedInbox([for (final uid in uids) envelope(uid: uid)]);
    expect(await sync.syncMailboxes(accountId), isA<Ok<List<MailboxRow>>>());
    // İlk indirme ve uzlaştırma turları sayfa sayfa çeker; hepsi inene dek.
    await syncInbox();
    for (var i = 0; i < 10; i++) {
      final result = await sync.loadOlder(
        accountId: accountId,
        mailbox: await box(SpecialUse.inbox),
      );
      expect(result, isA<Ok<int>>());
    }
    expect(await localUids(SpecialUse.inbox), uids);

    final ids = [
      for (final row in await (db.select(db.messages)).get()) row.id,
    ];
    for (final id in ids) {
      await repository.deleteMessages([id], undoWindow: undoWindow);
    }
    expect(await localUids(SpecialUse.inbox), isEmpty);

    await syncInbox(forceReconcile: true);
    expect(await localUids(SpecialUse.inbox), isEmpty);
  });

  test('çevrimdışı beklerken (işlem kuyrukta) eşitleme iletiyi geri getirmez; '
      'bağlantı gelince sunucuya uygulanır', () async {
    await seed([1, 2]);
    await repository.deleteMessages([(await rowOfUid(1)).id]);
    await repository.waitForQueue();

    // İşlem geri çekilmeye girmiş gibi: sunucuya gitmemiş, kuyrukta.
    // (kickQueue zaten çalıştıysa sunucuda uygulanmıştır; ikisi de tutarlı.)
    await syncInbox(forceReconcile: true);
    expect(await localUids(SpecialUse.inbox), [2]);
    await drainQueue();
    await syncInbox(forceReconcile: true);
    expect(await localUids(SpecialUse.inbox), [2]);
    expect(imap.store['INBOX']!.keys, [2]);
  });

  test('işlem biter bitmez gelen bayat sunucu görüntüsü iletiyi geri '
      'yazamaz (kısa süreli mezar taşı)', () async {
    await seed([1, 2]);
    final gone = imap.store['INBOX']![1]!;

    await repository.deleteMessages([(await rowOfUid(1)).id]);
    await drainQueue();
    expect(await localUids(SpecialUse.inbox), [2]);

    // Başka bir bağlantı işlemden ÖNCE aldığı sunucu görüntüsünü şimdi yazıyor.
    imap.store['INBOX']![1] = gone;
    await syncInbox(forceReconcile: true);
    expect(await localUids(SpecialUse.inbox), [2]);
  });

  test('geri alma pencerede iletiyi yerele geri getirir', () async {
    await seed([1, 2]);

    final handle = await repository.deleteMessages([
      (await rowOfUid(1)).id,
    ], undoWindow: undoWindow);
    expect(await localUids(SpecialUse.inbox), [2]);

    expect(await handle!.undo(), isTrue);
    expect(await localUids(SpecialUse.inbox), [1, 2]);
    await syncInbox(forceReconcile: true);
    expect(await localUids(SpecialUse.inbox), [1, 2]);
    expect(imap.store['INBOX']!.keys, containsAll([1, 2]));
  });

  test('sunucuda kalıcı başarısız silme iletiyi geri getirir ve kilitlenmez',
      () async {
    await seed([1, 2]);
    imap.failMove = const ServerFailure(detail: 'NO', isPermanent: true);

    await repository.deleteMessages([(await rowOfUid(1)).id]);
    await drainQueue();

    expect(await localUids(SpecialUse.inbox), [1, 2]);
    await syncInbox(forceReconcile: true);
    expect(await localUids(SpecialUse.inbox), [1, 2]);
  });

  test('UIDVALIDITY değişince eski UID kilidi yeni iletileri engellemez',
      () async {
    await seed([1, 2]);
    await repository.deleteMessages([
      (await rowOfUid(2)).id,
    ], undoWindow: undoWindow);

    // Sunucu klasörü yeniden oluşturdu: aynı UID numaraları başka iletiler.
    imap.uidValidity += 1;
    imap.seedInbox([envelope(uid: 1), envelope(uid: 2, subject: 'Yeni 2')]);
    await syncInbox();

    expect(await localUids(SpecialUse.inbox), [1, 2]);
  });
}
