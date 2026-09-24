import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/account_repository.dart';
import 'package:kaydet/data/repositories/folder_repository.dart';
import 'package:kaydet/data/repositories/mail_connection.dart';
import 'package:kaydet/data/repositories/sync_engine.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/domain/use_cases/folder_mapping.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

/// Web istemcisinde eklenen/silinen klasörler `syncMailboxes` ile yerele
/// yansımalı (bkz. `SyncController.syncFolders`, `AccountWatcher`).
void main() {
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
        email: 'a@b.com',
        username: 'a@b.com',
        imapHost: 'mail.b.com',
        smtpHost: 'mail.b.com',
      ),
    );
    await secureStore.writePassword(accountId, 'sifre');
    connection = MailConnection(
      database: db,
      secureStore: secureStore,
      imapService: imap,
    );
    sync = SyncEngine(database: db, connection: connection);
  });

  tearDown(() async {
    await connection.disconnect();
    await imap.dispose();
    await db.close();
  });

  const extra = RemoteMailbox(
    path: 'INBOX.Proje',
    name: 'Proje',
    delimiter: '.',
    specialUse: SpecialUse.custom,
  );

  test('web istemcisinde eklenen klasör yeniden eşitlemede gelir', () async {
    await sync.syncMailboxes(accountId);
    expect(
      (await db.mailboxesOf(accountId)).any((m) => m.path == extra.path),
      isFalse,
    );

    imap.mailboxes.add(extra);
    await sync.syncMailboxes(accountId);
    expect(
      (await db.mailboxesOf(accountId)).any((m) => m.path == extra.path),
      isTrue,
    );
  });

  test(
    'sync system roles with INBOX paths as UI roots and keeps custom nesting',
    () async {
      imap.mailboxes.add(extra);
      final result = await sync.syncMailboxes(accountId);

      expect(result, isA<Ok<List<MailboxRow>>>());
      final tree = buildFolderTree(await db.mailboxesOf(accountId));
      final depthByPath = {
        for (final node in tree) node.mailbox.path: node.depth,
      };
      for (final path in [
        'INBOX',
        'INBOX.Sent',
        'INBOX.Drafts',
        'INBOX.Trash',
        'INBOX.Junk',
        'INBOX.Archive',
      ]) {
        expect(depthByPath[path], 0, reason: '$path should be a UI root');
      }
      expect(depthByPath['INBOX.Proje'], 1);
    },
  );

  test('web istemcisinde silinen klasör yerelden de kalkar', () async {
    imap.mailboxes.add(extra);
    await sync.syncMailboxes(accountId);
    expect(
      (await db.mailboxesOf(accountId)).any((m) => m.path == extra.path),
      isTrue,
    );

    imap.mailboxes.removeWhere((m) => m.path == extra.path);
    final result = await sync.syncMailboxes(accountId);
    expect(
      (result as Ok<List<MailboxRow>>).value.any((m) => m.path == extra.path),
      isFalse,
    );

    expect(
      (await db.mailboxesOf(accountId)).any((m) => m.path == extra.path),
      isFalse,
    );
  });

  test('boş LIST yanıtı yerel klasörleri silmez', () async {
    await sync.syncMailboxes(accountId);
    final before = (await db.mailboxesOf(accountId)).length;
    expect(before, greaterThan(0));

    imap.mailboxes.clear();
    await sync.syncMailboxes(accountId);
    expect((await db.mailboxesOf(accountId)).length, before);
  });

  test(
    'aynı remote identity eşitlenirken yerel favorite ve sıra korunur',
    () async {
      imap.mailboxes.add(extra);
      await sync.syncMailboxes(accountId);
      final before = (await db.mailboxesOf(
        accountId,
      )).singleWhere((mailbox) => mailbox.path == extra.path);
      await db.setMailboxFavorite(before.id, true);
      await (db.update(db.mailboxes)..where((m) => m.id.equals(before.id)))
          .write(const MailboxesCompanion(sortOrder: Value(7)));

      await sync.syncMailboxes(accountId);
      final after = (await db.mailboxesOf(
        accountId,
      )).singleWhere((mailbox) => mailbox.path == extra.path);
      expect(after.id, before.id);
      expect(after.isFavorite, isTrue);
      expect(after.sortOrder, 7);
    },
  );

  group('createFolder üst klasör seçimi', () {
    late AccountRepository accounts;

    setUp(() async {
      accounts = AccountRepository(
        database: db,
        secureStore: InMemorySecureStore(),
        imapService: imap,
        smtpService: FakeSmtpService(),
        connection: connection,
      );
      await sync.syncMailboxes(accountId);
    });

    Future<MailboxRow> byPath(String path) async =>
        (await db.mailboxesOf(accountId)).firstWhere((m) => m.path == path);

    test('iç içe: seçilen üst klasörün altında, sunucu ayırıcısıyla', () async {
      final inbox = await byPath('INBOX');
      final a = await accounts.createFolder(
        accountId: accountId,
        name: 'Emsoft',
        parentMailboxId: inbox.id,
      );
      final emsoft = (a as Ok<MailboxRow>).value;
      expect(emsoft.path, 'INBOX.Emsoft');

      final b = await accounts.createFolder(
        accountId: accountId,
        name: 'Test',
        parentMailboxId: emsoft.id,
      );
      expect((b as Ok<MailboxRow>).value.path, 'INBOX.Emsoft.Test');
      expect(imap.commandLog, contains('create:INBOX.Emsoft.Test'));
    });

    test('kök düzey seçilince Gelen Kutusu altına girmez', () async {
      final r = await accounts.createFolder(
        accountId: accountId,
        name: 'Kök',
        atRoot: true,
      );
      expect((r as Ok<MailboxRow>).value.path, 'Kök');
    });

    test('parametresiz eski davranış: Gelen Kutusu altında', () async {
      final r = await accounts.createFolder(accountId: accountId, name: 'X');
      expect((r as Ok<MailboxRow>).value.path, 'INBOX.X');
    });

    test('farklı üst klasörlerde aynı ad serbest, aynı üstte hata', () async {
      final inbox = await byPath('INBOX');
      final sent = await byPath('INBOX.Sent');
      final ok1 = await accounts.createFolder(
        accountId: accountId,
        name: '2026',
        parentMailboxId: inbox.id,
      );
      final ok2 = await accounts.createFolder(
        accountId: accountId,
        name: '2026',
        parentMailboxId: sent.id,
      );
      expect(ok1, isA<Ok<MailboxRow>>());
      expect(ok2, isA<Ok<MailboxRow>>());

      final dup = await accounts.createFolder(
        accountId: accountId,
        name: '2026',
        parentMailboxId: inbox.id,
      );
      expect((dup as Err<MailboxRow>).failure, isA<DuplicateFolderFailure>());
    });

    test('boş ad ve ayırıcı içeren ad reddedilir', () async {
      final empty = await accounts.createFolder(
        accountId: accountId,
        name: ' ',
      );
      expect(
        (empty as Err<MailboxRow>).failure,
        isA<InvalidFolderNameFailure>(),
      );
      final dotted = await accounts.createFolder(
        accountId: accountId,
        name: 'a.b',
      );
      expect(
        (dotted as Err<MailboxRow>).failure,
        isA<InvalidFolderNameFailure>(),
      );
    });

    test('başka hesabın klasörü üst klasör olarak kabul edilmez', () async {
      final other = await db.insertAccount(
        AccountsCompanion.insert(
          email: 'c@d.com',
          username: 'c@d.com',
          imapHost: 'mail.d.com',
          smtpHost: 'mail.d.com',
        ),
      );
      final foreign = await db.upsertMailbox(
        MailboxesCompanion.insert(
          accountId: other,
          path: 'INBOX.Emsoft',
          name: 'Emsoft',
        ),
      );
      final r = await accounts.createFolder(
        accountId: accountId,
        name: 'Test',
        parentMailboxId: foreign,
      );
      expect((r as Err<MailboxRow>).failure, isA<MailboxNotFoundFailure>());
    });

    test(
      'rename, move ve delete başka hesaptaki folder kimliğini reddeder',
      () async {
        final other = await db.insertAccount(
          AccountsCompanion.insert(
            email: 'foreign@example.com',
            username: 'foreign@example.com',
            imapHost: 'mail.foreign.com',
            smtpHost: 'mail.foreign.com',
          ),
        );
        final foreignId = await db.upsertMailbox(
          MailboxesCompanion.insert(
            accountId: other,
            path: 'INBOX.Private',
            name: 'Private',
            specialUse: const Value(SpecialUse.custom),
          ),
        );
        final repo = FolderRepository(database: db, connection: connection);

        expect(
          (await repo.renameFolder(
            accountId: accountId,
            mailboxId: foreignId,
            newName: 'Changed',
          )),
          isA<Err<void>>(),
        );
        expect(
          (await repo.moveFolder(
            accountId: accountId,
            mailboxId: foreignId,
            newParentId: null,
          )),
          isA<Err<void>>(),
        );
        expect(
          (await repo.deleteFolder(accountId: accountId, mailboxId: foreignId)),
          isA<Err<void>>(),
        );
        expect(
          imap.commandLog.where((command) => command.startsWith('rename:')),
          isEmpty,
        );
        expect(
          imap.commandLog.where((command) => command.startsWith('delete:')),
          isEmpty,
        );
      },
    );

    test('move kendi alt ağacına döngü oluşturamaz', () async {
      final root =
          (await accounts.createFolder(
                    accountId: accountId,
                    name: 'Parent',
                    atRoot: true,
                  )
                  as Ok<MailboxRow>)
              .value;
      final child =
          (await accounts.createFolder(
                    accountId: accountId,
                    name: 'Child',
                    parentMailboxId: root.id,
                  )
                  as Ok<MailboxRow>)
              .value;
      final repo = FolderRepository(database: db, connection: connection);

      final result = await repo.moveFolder(
        accountId: accountId,
        mailboxId: root.id,
        newParentId: child.id,
      );
      expect(result, isA<Err<void>>());
      expect(
        imap.commandLog.where((command) => command.startsWith('rename:')),
        isEmpty,
      );
    });

    test(
      'reorder yalnızca root kardeşlerin verilen sırasını günceller',
      () async {
        await accounts.createFolder(
          accountId: accountId,
          name: 'One',
          atRoot: true,
        );
        await accounts.createFolder(
          accountId: accountId,
          name: 'Two',
          atRoot: true,
        );
        final repo = FolderRepository(database: db, connection: connection);
        final before = await db.mailboxesOf(accountId);
        final roots = before.where((mailbox) {
          final delimiter = mailbox.delimiter;
          final split = delimiter.isEmpty
              ? -1
              : mailbox.path.lastIndexOf(delimiter);
          return split <= 0;
        }).toList();
        final orderedIds = roots.reversed.map((mailbox) => mailbox.id).toList();

        await repo.reorderSiblings(
          accountId: accountId,
          parentMailboxId: null,
          orderedIds: orderedIds,
        );

        final after = await db.mailboxesOf(accountId);
        final afterRoots = after.where((mailbox) {
          final delimiter = mailbox.delimiter;
          final split = delimiter.isEmpty
              ? -1
              : mailbox.path.lastIndexOf(delimiter);
          return split <= 0;
        }).toList();
        expect(afterRoots.map((mailbox) => mailbox.id).toList(), orderedIds);
      },
    );
  });
}
