import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/app/providers.dart';
import 'package:kaydet/app/push_stubs.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/services/notification_service.dart';
import 'package:kaydet/domain/models/mail_models.dart';
import 'package:kaydet/domain/models/push_stub.dart';

import 'helpers/test_db.dart';

class _FakeNotifications extends NotificationService {
  _FakeNotifications(this.stubs);

  List<PushStub> stubs;
  final removed = <(int, List<int>)>[];

  @override
  Future<List<PushStub>> takePushStubs() async => stubs;

  @override
  Future<void> removePushStubs(int accountId, List<int> uids) async {
    removed.add((accountId, uids));
  }
}

PushStub _stub(int accountId, int uid) => PushStub(
  accountId: accountId,
  uid: uid,
  from: 'Ali',
  subject: 'Konu $uid',
  date: DateTime.utc(2026, 10, 7, 1),
);

void main() {
  late AppDatabase db;
  late int accountId;
  late int inboxId;
  late _FakeNotifications notifications;
  late ProviderContainer container;

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
    inboxId = await db.upsertMailbox(
      MailboxesCompanion.insert(
        accountId: accountId,
        path: 'INBOX',
        name: 'Gelen',
        specialUse: const Value(SpecialUse.inbox),
        uidNext: const Value(10),
      ),
    );
    notifications = _FakeNotifications([
      _stub(accountId, 10),
      _stub(accountId, 11),
      _stub(accountId, 5), // eşitlemenin zaten geçtiği uid
    ]);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        notificationServiceProvider.overrideWithValue(notifications),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('refresh eşitlemenin geçtiği uid\'leri düşürür ve depodan siler', () async {
    await container.read(pushStubsProvider.notifier).refresh();
    expect(container.read(pushStubsProvider).map((s) => s.uid), [10, 11]);
    expect(notifications.removed.single.$1, accountId);
    expect(notifications.removed.single.$2, [5]);
  });

  test('reconcile, uidNext ilerleyince kayıtları kaldırır', () async {
    final notifier = container.read(pushStubsProvider.notifier);
    await notifier.refresh();
    await db.updateMailboxSync(inboxId, uidNext: 12);
    await notifier.reconcile();
    expect(container.read(pushStubsProvider), isEmpty);
  });
}
