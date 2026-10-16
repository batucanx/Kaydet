import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/notification_target_resolver.dart';
import 'package:kaydet/domain/models/mail_models.dart';

import 'helpers/test_db.dart';

/// Bildirimden ileti açma: hedef, TÜM eşitleme beklenmeden çözülür.
void main() {
  late AppDatabase db;
  late int accountId;
  late MailboxRow inbox;

  Future<int> insertMessage({
    required int uid,
    String? header,
    int? mailboxId,
  }) => db
      .into(db.messages)
      .insert(
        MessagesCompanion.insert(
          accountId: accountId,
          mailboxId: mailboxId ?? inbox.id,
          dateUtc: DateTime.utc(2026, 10, 1),
          uid: Value(uid),
          messageIdHeader: Value(header),
        ),
      );

  NotificationTargetResolver resolverWith(List<TargetFetcher> fetchers) =>
      NotificationTargetResolver(
        database: db,
        fetchers: fetchers,
        fetchTimeout: const Duration(milliseconds: 300),
        syncWait: const Duration(milliseconds: 400),
      );

  Future<Result<int?>> down({
    required int accountId,
    required MailboxRow mailbox,
    required int uid,
    int? expectedUidValidity,
  }) async => const Err(ConnectionFailure(detail: 'down'));

  Future<Result<int?>> absent({
    required int accountId,
    required MailboxRow mailbox,
    required int uid,
    int? expectedUidValidity,
  }) async => const Ok(null);

  Future<Result<int?>> storing({
    required int accountId,
    required MailboxRow mailbox,
    required int uid,
    int? expectedUidValidity,
  }) async => Ok(await insertMessage(uid: uid));

  setUp(() async {
    db = createTestDatabase();
    accountId = await db.insertAccount(
      AccountsCompanion.insert(
        email: 'a@b.com',
        username: 'a@b.com',
        imapHost: 'mail.b.com',
        smtpHost: 'mail.b.com',
      ),
    );
    final id = await db.upsertMailbox(
      MailboxesCompanion.insert(
        accountId: accountId,
        path: 'INBOX',
        name: 'Gelen',
        specialUse: const Value(SpecialUse.inbox),
        uidValidity: const Value(1000),
      ),
    );
    inbox = (await db.mailboxById(id))!;
  });

  tearDown(() => db.close());

  test('ileti yerelde varsa sunucuya hiç gidilmez', () async {
    final rowId = await insertMessage(uid: 7);
    var fetched = 0;
    final resolver = resolverWith([
      ({
        required accountId,
        required mailbox,
        required uid,
        expectedUidValidity,
      }) async {
        fetched++;
        return const Ok(null);
      },
    ]);

    final result = await resolver.resolve(
      accountId: accountId,
      uid: 7,
      uidValidity: 1000,
    );

    expect(result.isFound, isTrue);
    expect(result.message!.id, rowId);
    expect(result.source, TargetSource.local);
    expect(fetched, 0);
  });

  test('yerelde yoksa yalnızca o ileti sunucudan getirilir', () async {
    int? askedUid;
    final resolver = resolverWith([
      ({
        required accountId,
        required mailbox,
        required uid,
        expectedUidValidity,
      }) {
        askedUid = uid;
        return storing(accountId: accountId, mailbox: mailbox, uid: uid);
      },
    ]);

    final result = await resolver.resolve(accountId: accountId, uid: 99);

    expect(askedUid, 99);
    expect(result.source, TargetSource.server);
    expect(result.message!.uid, 99);
  });

  test('ayrı bağlantı başarısızsa ana bağlantıya geçilir', () async {
    final resolver = resolverWith([down, storing]);

    final result = await resolver.resolve(accountId: accountId, uid: 5);

    expect(result.source, TargetSource.server);
  });

  test('UIDVALIDITY değiştiyse yerel aynı UID yanlış iletiyi açmaz', () async {
    // Yerelde uid 7 başka bir iletiye ait (klasör yeniden numaralanmış).
    await insertMessage(uid: 7, header: 'old@x');
    int? expected;
    final resolver = resolverWith([
      ({
        required accountId,
        required mailbox,
        required uid,
        expectedUidValidity,
      }) {
        expected = expectedUidValidity;
        return absent(accountId: accountId, mailbox: mailbox, uid: uid);
      },
    ]);

    final result = await resolver.resolve(
      accountId: accountId,
      uid: 7,
      uidValidity: 2000,
      messageIdHeader: '<new@x>',
    );

    expect(expected, 2000);
    expect(result.isFound, isFalse);
    expect(result.failure, TargetFailure.notFound);
  });

  test('Message-ID çelişiyorsa aynı UID kabul edilmez', () async {
    await insertMessage(uid: 7, header: 'other@x');
    final resolver = resolverWith([absent]);

    final result = await resolver.resolve(
      accountId: accountId,
      uid: 7,
      messageIdHeader: '<wanted@x>',
    );

    expect(result.failure, TargetFailure.notFound);
  });

  test('ileti başka klasöre taşınmışsa Message-ID ile bulunur', () async {
    final archiveId = await db.upsertMailbox(
      MailboxesCompanion.insert(
        accountId: accountId,
        path: 'Archive',
        name: 'Arşiv',
        specialUse: const Value(SpecialUse.archive),
      ),
    );
    final rowId = await insertMessage(
      uid: 3,
      header: 'moved@x',
      mailboxId: archiveId,
    );
    final resolver = resolverWith([down]);

    final result = await resolver.resolve(
      accountId: accountId,
      uid: 70,
      messageIdHeader: '<moved@x>',
    );

    expect(result.message?.id, rowId);
    expect(result.message?.mailboxId, archiveId);
  });

  test('sunucu "yok" derse notFound döner, sonsuz beklemez', () async {
    final resolver = resolverWith([absent]);

    final result = await resolver.resolve(accountId: accountId, uid: 404);

    expect(result.failure, TargetFailure.notFound);
  });

  test('sunucuya ulaşılamazsa eşitlemenin getirmesi beklenir', () async {
    final resolver = resolverWith([down]);
    final pending = resolver.resolve(accountId: accountId, uid: 12);

    // Tam eşitleme (başka yol) iletiyi biraz sonra yazar.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final rowId = await insertMessage(uid: 12);

    final result = await pending;
    expect(result.source, TargetSource.awaitedSync);
    expect(result.message!.id, rowId);
  });

  test('eşitleme de getirmezse unavailable döner', () async {
    final resolver = resolverWith([down]);

    final result = await resolver.resolve(accountId: accountId, uid: 12);

    expect(result.failure, TargetFailure.unavailable);
  });

  test('zaman aşımına uğrayan sunucu denemesi sıradakine geçer', () async {
    final resolver = resolverWith([
      ({
        required accountId,
        required mailbox,
        required uid,
        expectedUidValidity,
      }) => Completer<Result<int?>>().future, // asla bitmez
      storing,
    ]);

    final result = await resolver.resolve(accountId: accountId, uid: 8);

    expect(result.source, TargetSource.server);
  });

  test('yerel bildirim yükü doğrudan satır kimliğidir', () async {
    final rowId = await insertMessage(uid: 1);
    final resolver = resolverWith(const []);

    expect((await resolver.resolveLocalRow(rowId)).message?.id, rowId);
    expect(
      (await resolver.resolveLocalRow(rowId + 100)).failure,
      TargetFailure.notFound,
    );
  });
}
