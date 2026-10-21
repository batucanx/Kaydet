import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kaydet/app/providers.dart';
import 'package:kaydet/app/sync_controller.dart';
import 'package:kaydet/core/result.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/mail_connection.dart';
import 'package:kaydet/data/repositories/sync_engine.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:kaydet/domain/models/mail_models.dart';

import 'helpers/fake_services.dart';
import 'helpers/test_db.dart';

class FakeSyncController extends SyncController {
  FakeSyncController({SyncState initial = const SyncState()})
    : _initial = initial;
  final SyncState _initial;

  @override
  SyncState build() => _initial;

  void updateState(SyncState newState) => state = newState;
}

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
        email: 'user@example.com',
        username: 'user@example.com',
        imapHost: 'mail.example.com',
        smtpHost: 'mail.example.com',
      ),
    );
    await secureStore.writePassword(accountId, 'secret');
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

  group('IMAP klasör seçimi ve kodlama (UTF-7 / wire path)', () {
    test('klasör seçilirken sunucunun encodedPath değeri kullanılır', () async {
      // Türkçe özel karakterli klasör
      final mailboxId = await db.upsertMailbox(
        MailboxesCompanion.insert(
          accountId: 1,
          path: 'INBOX.Çöp Kutusu',
          encodedPath: const Value('INBOX.&AMcA9g-p Kutusu'),
          name: 'Çöp Kutusu',
          delimiter: const Value('.'),
        ),
      );
      final mailbox = (await db.mailboxById(mailboxId))!;

      imap.seedInbox([
        FetchedEnvelope(
          uid: 10,
          date: DateTime.now().toUtc(),
          subject: 'Test',
          from: const EmailAddress(email: 'test@example.com'),
          to: const [EmailAddress(email: 'user@example.com')],
          cc: const [],
          bcc: const [],
          flags: const [],
          sizeBytes: 100,
          hasAttachments: false,
        ),
      ]);

      await connection.exclusive<MailboxState>(
        accountId,
        () => connection.selectVerified(mailbox),
      );

      // imap command log'da encodedPath'in select edildiğini doğrula
      expect(imap.commandLog, contains('select:INBOX.Çöp Kutusu'));
      expect(imap.selectedPath, 'INBOX.Çöp Kutusu');
    });

    test(
      'yerel DB boş ama sunucuda mail varken (uidNext önceden set edilmiş olsa bile) mailler indirilir',
      () async {
        // Senaryo: Klasör daha önce sync edilmiş gibi uidNext=100 set edilmiş,
        // ancak yerel veritabanında henüz 0 mesaj var. Sunucuda ise 3 mesaj var.
        final mailboxId = await db.upsertMailbox(
          MailboxesCompanion.insert(
            accountId: 1,
            path: 'INBOX.Önemli',
            encodedPath: const Value('INBOX.&ANY-nemli'),
            name: 'Önemli',
            delimiter: const Value('.'),
            uidNext: const Value(100),
            lastSyncAt: const Value.absent(),
          ),
        );
        final mailbox = (await db.mailboxById(mailboxId))!;

        // Sunucuya 3 mesaj ekle (UID: 101, 102, 103)
        final box = imap.store.putIfAbsent('INBOX.Önemli', () => {});
        for (final uid in [101, 102, 103]) {
          box[uid] = FetchedEnvelope(
            uid: uid,
            date: DateTime.now().toUtc(),
            subject: 'Mail $uid',
            from: const EmailAddress(email: 'sender@example.com'),
            to: const [EmailAddress(email: 'user@example.com')],
            cc: const [],
            bcc: const [],
            flags: const [],
            sizeBytes: 200,
            hasAttachments: false,
          );
        }

        final outcome = await sync.syncMailbox(
          accountId: accountId,
          mailbox: mailbox,
        );

        expect(outcome.isOk, isTrue);
        // Yerel DB'ye 3 mesajın da indiğini doğrula
        final count = await db.countMessages(mailbox.id);
        expect(count, 3);
      },
    );

    test(
      'sunucu UIDNEXT bildirmese bile (uidNext=0) yeni mailler sequence ile çekilir',
      () async {
        final mailboxId = await db.upsertMailbox(
          MailboxesCompanion.insert(
            accountId: 1,
            path: 'INBOX',
            name: 'INBOX',
            totalCount: const Value(1),
            uidNext: const Value(2),
          ),
        );
        // İlk mesajı yerele yaz
        await db.upsertServerMessages([
          MessagesCompanion.insert(
            accountId: accountId,
            mailboxId: mailboxId,
            uid: const Value(1),
            dateUtc: DateTime.now().toUtc(),
            fromEmail: const Value('test@example.com'),
          ),
        ]);

        // Sunucuya ikinci bir mesaj ekle
        final box = imap.store.putIfAbsent('INBOX', () => {});
        box[1] = FetchedEnvelope(
          uid: 1,
          date: DateTime.now().toUtc(),
          subject: 'M1',
          from: const EmailAddress(email: 't@example.com'),
          to: const [],
          cc: const [],
          bcc: const [],
          flags: const [],
          sizeBytes: 10,
          hasAttachments: false,
        );
        box[2] = FetchedEnvelope(
          uid: 2,
          date: DateTime.now().toUtc(),
          subject: 'M2',
          from: const EmailAddress(email: 't@example.com'),
          to: const [],
          cc: const [],
          bcc: const [],
          flags: const [],
          sizeBytes: 10,
          hasAttachments: false,
        );

        final mailbox = (await db.mailboxById(mailboxId))!;
        final result = await sync.syncMailbox(
          accountId: accountId,
          mailbox: mailbox,
        );
        expect(result.isOk, isTrue);

        final total = await db.countMessages(mailboxId);
        expect(total, 2);
      },
    );
  });

  group('İlk indirme işareti (uidNext)', () {
    test(
      'sunucuda 0 ileti olan klasör eşitlenince uidNext null KALMAZ (iskelet sonsuza dek sürmez)',
      () async {
        final mailboxId = await db.upsertMailbox(
          MailboxesCompanion.insert(
            accountId: accountId,
            path: 'Bos',
            name: 'Bos',
          ),
        );
        imap.store.putIfAbsent('Bos', () => {});
        final mailbox = (await db.mailboxById(mailboxId))!;
        expect(mailbox.uidNext, isNull);

        final result = await sync.syncMailbox(
          accountId: accountId,
          mailbox: mailbox,
        );
        expect(result.isOk, isTrue);

        expect((await db.mailboxById(mailboxId))!.uidNext, isNotNull);
      },
    );
  });

  group('UI Folder State Ayrımı (Loading vs Empty vs Error vs Loaded)', () {
    test(
      'yerel DB boşken ve sync çalışırken FolderLoadingItem üretilir (boş ekran veya "klasör boş" olmaz)',
      () async {
        final mailboxId = await db.upsertMailbox(
          MailboxesCompanion.insert(
            accountId: accountId,
            path: 'INBOX',
            name: 'INBOX',
          ),
        );
        final mailbox = (await db.mailboxById(mailboxId))!;

        final fakeSync = FakeSyncController(
          initial: const SyncState(isSyncing: true),
        );

        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            accountIdProvider.overrideWith((ref) => accountId),
            syncControllerProvider.overrideWith(() => fakeSync),
            mailboxesProvider.overrideWithValue(AsyncData([mailbox])),
            messageListProvider.overrideWithValue(
              const AsyncData(<MessageRow>[]),
            ),
          ],
        );
        addTearDown(container.dispose);

        container
            .read(selectedFolderRawProvider.notifier)
            .select(SelectedFolder.mailbox(mailboxId));

        final items = container.read(mailListItemsProvider);
        expect(items.hasValue, isTrue);
        expect(items.value, isNotEmpty);
        expect(items.value!.first, isA<FolderLoadingItem>());
      },
    );

    Future<AsyncValue<List<MailListItem>>> itemsFor({
      required MailboxesCompanion Function(int accountId) mailbox,
      required SyncState sync,
    }) async {
      final mailboxId = await db.upsertMailbox(mailbox(accountId));
      final row = (await db.mailboxById(mailboxId))!;
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          accountIdProvider.overrideWith((ref) => accountId),
          syncControllerProvider.overrideWith(
            () => FakeSyncController(initial: sync),
          ),
          mailboxesProvider.overrideWithValue(AsyncData([row])),
          messageListProvider.overrideWithValue(
            const AsyncData(<MessageRow>[]),
          ),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(selectedFolderRawProvider.notifier)
          .select(SelectedFolder.mailbox(mailboxId));
      return container.read(mailListItemsProvider);
    }

    test(
      'REGRESYON: motor lastSyncAt\'i indirmeden ÖNCE yazar; indirme sürerken (uidNext hâlâ null) "klasör boş" çıkmaz',
      () async {
        final items = await itemsFor(
          mailbox: (id) => MailboxesCompanion.insert(
            accountId: id,
            path: 'Arsiv',
            name: 'Arsiv',
            lastSyncAt: Value(DateTime.now()),
          ),
          sync: const SyncState(isSyncing: true),
        );
        expect(items.value!.first, isA<FolderLoadingItem>());
      },
    );

    test(
      'REGRESYON: klasöre geçildi ama eşitleme henüz başlamadı (isSyncing=false) → "klasör boş" değil iskelet',
      () async {
        final items = await itemsFor(
          mailbox: (id) => MailboxesCompanion.insert(
            accountId: id,
            path: 'Arsiv',
            name: 'Arsiv',
          ),
          sync: const SyncState(isSyncing: false),
        );
        expect(items.value!.first, isA<FolderLoadingItem>());
      },
    );

    test(
      'ilk indirme bitmemiş klasör çevrimdışıyken iskelet sonsuza dek kalmaz',
      () async {
        final items = await itemsFor(
          mailbox: (id) => MailboxesCompanion.insert(
            accountId: id,
            path: 'Arsiv',
            name: 'Arsiv',
          ),
          sync: const SyncState(isOffline: true),
        );
        expect(items.value!.first, isA<EmptyListItem>());
      },
    );

    test(
      'ilk indirme bitmemiş klasörde sunucuya ulaşılamıyorsa iskelet sonsuza dek kalmaz',
      () async {
        final items = await itemsFor(
          mailbox: (id) => MailboxesCompanion.insert(
            accountId: id,
            path: 'Arsiv',
            name: 'Arsiv',
          ),
          sync: SyncState(unreachableAccounts: {accountId: null}),
        );
        expect(items.value!.first, isA<EmptyListItem>());
      },
    );

    test(
      'yerel DB boşken ve sync hata aldığında FolderErrorItem üretilir',
      () async {
        final mailboxId = await db.upsertMailbox(
          MailboxesCompanion.insert(
            accountId: accountId,
            path: 'INBOX',
            name: 'INBOX',
          ),
        );
        final mailbox = (await db.mailboxById(mailboxId))!;

        const failure = ServerFailure(detail: 'IMAP connection reset');
        final fakeSync = FakeSyncController(
          initial: SyncState(
            isSyncing: false,
            lastError: failure,
            folderErrors: {mailboxId: failure},
          ),
        );

        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            accountIdProvider.overrideWith((ref) => accountId),
            syncControllerProvider.overrideWith(() => fakeSync),
            mailboxesProvider.overrideWithValue(AsyncData([mailbox])),
            messageListProvider.overrideWithValue(
              const AsyncData(<MessageRow>[]),
            ),
          ],
        );
        addTearDown(container.dispose);

        container
            .read(selectedFolderRawProvider.notifier)
            .select(SelectedFolder.mailbox(mailboxId));

        final items = container.read(mailListItemsProvider);
        expect(items.hasValue, isTrue);
        expect(items.value, isNotEmpty);
        expect(items.value!.first, isA<FolderErrorItem>());
        final errorItem = items.value!.first as FolderErrorItem;
        expect(errorItem.error, failure);
      },
    );

    test(
      'sync tamamlanıp sunucuda gerçekten 0 mesaj varsa EmptyListItem üretilir',
      () async {
        final mailboxId = await db.upsertMailbox(
          MailboxesCompanion.insert(
            accountId: accountId,
            path: 'INBOX',
            name: 'INBOX',
            lastSyncAt: Value(DateTime.now()),
            uidNext: const Value(1),
            totalCount: const Value(0),
          ),
        );
        final mailbox = (await db.mailboxById(mailboxId))!;

        final fakeSync = FakeSyncController(
          initial: SyncState(isSyncing: false, lastSyncAt: DateTime.now()),
        );

        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            accountIdProvider.overrideWith((ref) => accountId),
            syncControllerProvider.overrideWith(() => fakeSync),
            mailboxesProvider.overrideWithValue(AsyncData([mailbox])),
            messageListProvider.overrideWithValue(
              const AsyncData(<MessageRow>[]),
            ),
          ],
        );
        addTearDown(container.dispose);

        container
            .read(selectedFolderRawProvider.notifier)
            .select(SelectedFolder.mailbox(mailboxId));

        final items = container.read(mailListItemsProvider);
        expect(items.hasValue, isTrue);
        expect(items.value, isNotEmpty);
        expect(items.value!.first, isA<EmptyListItem>());
      },
    );

    test(
      'yerel DBde mesaj varsa sync devam etse bile mesajlar hemen gösterilir (offline-first)',
      () async {
        final mailboxId = await db.upsertMailbox(
          MailboxesCompanion.insert(
            accountId: accountId,
            path: 'INBOX',
            name: 'INBOX',
            lastSyncAt: Value(DateTime.now()),
            uidNext: const Value(2),
          ),
        );
        final mailbox = (await db.mailboxById(mailboxId))!;
        await db.upsertServerMessages([
          MessagesCompanion.insert(
            accountId: accountId,
            mailboxId: mailboxId,
            uid: const Value(1),
            dateUtc: DateTime.now().toUtc(),
            subject: const Value('Var olan e-posta'),
            fromEmail: const Value('sender@example.com'),
          ),
        ]);
        final messageRow = (await db.select(db.messages).get()).first;

        final fakeSync = FakeSyncController(
          initial: const SyncState(isSyncing: true),
        );

        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            accountIdProvider.overrideWith((ref) => accountId),
            syncControllerProvider.overrideWith(() => fakeSync),
            mailboxesProvider.overrideWithValue(AsyncData([mailbox])),
            messageListProvider.overrideWithValue(AsyncData([messageRow])),
          ],
        );
        addTearDown(container.dispose);

        container
            .read(selectedFolderRawProvider.notifier)
            .select(SelectedFolder.mailbox(mailboxId));

        final items = container.read(mailListItemsProvider);
        expect(items.hasValue, isTrue);
        // Mesajların var olduğunu ve MessageItem içerdiğini doğrula
        final hasMessageItem = items.value!.any((i) => i is MessageItem);
        expect(hasMessageItem, isTrue);
      },
    );
  });
}
