import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/domain/use_cases/folder_mapping.dart';

import 'helpers/test_db.dart';

void main() {
  late AppDatabase db;
  late int accountId;

  setUp(() async {
    db = createTestDatabase();
    accountId = await db.insertAccount(
      AccountsCompanion.insert(
        email: 'tree@example.com',
        username: 'tree@example.com',
        imapHost: 'mail.example.com',
        smtpHost: 'mail.example.com',
      ),
    );
  });

  tearDown(() => db.close());

  Future<MailboxRow> add(
    String path,
    String name, {
    String delimiter = '/',
    bool selectable = true,
    int? forAccount,
  }) async {
    final id = await db.upsertMailbox(
      MailboxesCompanion.insert(
        accountId: forAccount ?? accountId,
        path: path,
        name: name,
        delimiter: Value(delimiter),
        isSelectable: Value(selectable),
      ),
    );
    return (await db.mailboxById(id))!;
  }

  test(
    'delimiter üzerinden gerçek parent-child ağacı ve depth üretir',
    () async {
      await add('Müşteriler', 'Müşteriler');
      await add('Müşteriler/XYZ', 'XYZ');
      await add('Müşteriler/ABC', 'ABC');
      await add('Müşteriler/ABC/Sözleşmeler', 'Sözleşmeler');

      final tree = buildFolderTree(await db.mailboxesOf(accountId));
      expect(
        tree.map((node) => '${node.mailbox.name}:${node.depth}').toList(),
        ['Müşteriler:0', 'ABC:1', 'Sözleşmeler:2', 'XYZ:1'],
      );
    },
  );

  test(
    'sistem klasörlerini UI köküne alıp Inbox altındaki custom klasörü korur',
    () async {
      Future<void> addWithUse(String path, String name, SpecialUse use) async {
        await db.upsertMailbox(
          MailboxesCompanion.insert(
            accountId: accountId,
            path: path,
            name: name,
            specialUse: Value(use),
            delimiter: const Value('.'),
            sortOrder: Value(FolderMapping.sortOrderFor(use)),
          ),
        );
      }

      await addWithUse('INBOX', 'Gelen Kutusu', SpecialUse.inbox);
      await addWithUse('INBOX.Sent', 'Gönderilenler', SpecialUse.sent);
      await addWithUse('INBOX.Drafts', 'Taslaklar', SpecialUse.drafts);
      await addWithUse('INBOX.Archive', 'Arşiv', SpecialUse.archive);
      await addWithUse('INBOX.Projeler', 'Projeler', SpecialUse.custom);
      await addWithUse('INBOX.Projeler.2026', '2026', SpecialUse.custom);

      final tree = buildFolderTree(await db.mailboxesOf(accountId));
      expect(
        tree.map((node) => '${node.mailbox.name}:${node.depth}').toList(),
        [
          'Gelen Kutusu:0',
          'Projeler:1',
          '2026:2',
          'Gönderilenler:0',
          'Arşiv:0',
          'Taslaklar:0',
        ],
      );
    },
  );

  test(
    'sistem klasörü köke taşınırken altındaki custom IMAP klasörü kalır',
    () async {
      await db.upsertMailbox(
        MailboxesCompanion.insert(
          accountId: accountId,
          path: 'INBOX',
          name: 'Gelen Kutusu',
          specialUse: const Value(SpecialUse.inbox),
        ),
      );
      await db.upsertMailbox(
        MailboxesCompanion.insert(
          accountId: accountId,
          path: 'INBOX.Sent',
          name: 'Gönderilenler',
          specialUse: const Value(SpecialUse.sent),
        ),
      );
      await db.upsertMailbox(
        MailboxesCompanion.insert(
          accountId: accountId,
          path: 'INBOX.Sent.Özel',
          name: 'Özel',
          specialUse: const Value(SpecialUse.custom),
        ),
      );

      final tree = buildFolderTree(await db.mailboxesOf(accountId));
      expect(
        tree.map((node) => '${node.mailbox.name}:${node.depth}').toList(),
        ['Gelen Kutusu:0', 'Gönderilenler:0', 'Özel:1'],
      );
    },
  );

  test('aynı remote path farklı hesaplarda birbirine bağlanmaz', () async {
    final secondAccount = await db.insertAccount(
      AccountsCompanion.insert(
        email: 'other@example.com',
        username: 'other@example.com',
        imapHost: 'mail.other.com',
        smtpHost: 'mail.other.com',
      ),
    );
    await add('Shared', 'Shared');
    await add('Shared/Child', 'Child', forAccount: secondAccount);

    final tree = buildFolderTree(await db.select(db.mailboxes).get());
    final child = tree.singleWhere((node) => node.mailbox.name == 'Child');
    expect(child.depth, 0);
  });

  test(
    'seçilemeyen ara klasörü gizlerken alt ağacın ilişkisi korunur',
    () async {
      await add('Root', 'Root');
      await add('Root/Container', 'Container', selectable: false);
      await add('Root/Container/Visible', 'Visible');

      final tree = buildFolderTree(
        await db.mailboxesOf(accountId),
        include: (mailbox) => mailbox.isSelectable,
      );
      expect(
        tree.map((node) => '${node.mailbox.name}:${node.depth}').toList(),
        ['Root:0', 'Visible:1'],
      );
    },
  );

  test('rename sonrası Drift folder watch yeni satırı yayınlar', () async {
    final folder = await add('Parent/Before', 'Before');
    final watchExpectation = expectLater(
      db.watchMailboxes(accountId).take(2),
      emitsInOrder([
        contains(predicate<MailboxRow>((row) => row.name == 'Before')),
        contains(predicate<MailboxRow>((row) => row.name == 'After')),
      ]),
    );
    await db.renameMailboxTree(
      mailboxId: folder.id,
      oldPath: folder.path,
      newPath: 'Parent/After',
      newName: 'After',
      delimiter: folder.delimiter,
    );
    await watchExpectation;
  });
}
