import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/app/providers.dart';
import 'package:kaydet/app/remote_push_controller.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/remote_push_sync.dart';
import 'package:kaydet/data/services/app_settings.dart';
import 'package:kaydet/data/services/push_backend_client.dart';
import 'package:kaydet/data/services/push_token_source.dart';
import 'package:kaydet/data/services/secure_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/test_db.dart';

class _FakeApi implements RemotePushApi {
  @override
  String get baseUrl => 'https://test.example.com';

  bool fail = false;
  final List<RemotePushAccount> upserted = [];
  final Set<int> registered = {};

  @override
  Future<List<int>> listRegisteredAccountIds(String pushToken) async {
    if (fail) throw const PushBackendException(503);
    return registered.toList();
  }

  @override
  Future<void> upsertAccount(RemotePushAccount account) async {
    if (fail) throw const PushBackendException(503);
    upserted.add(account);
    registered.add(account.clientAccountId);
  }

  @override
  Future<void> deleteAccount({
    required String pushToken,
    required int clientAccountId,
  }) async {
    registered.remove(clientAccountId);
  }

  @override
  Future<void> deleteDevice(String pushToken) async => registered.clear();
}

class _MemoryStore implements RegistrationStore {
  RegistrationSnapshot snapshot = const RegistrationSnapshot();

  @override
  RegistrationSnapshot read() => snapshot;

  @override
  Future<void> write(RegistrationSnapshot value) async => snapshot = value;
}

class _FakeTokenSource implements PushTokenSource {
  _FakeTokenSource(this.token);

  String? token;
  final StreamController<String> controller = StreamController.broadcast();

  @override
  Future<String?> load() async => token;

  @override
  Stream<String> get refreshes => controller.stream;
}

/// `RemotePushController`ın `ServerPushState` yayını: Android'de ön plan
/// servisinin yedek olarak ne zaman çalışacağını bu durum belirler.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late InMemorySecureStore secure;
  late _FakeApi api;
  late AppSettingsStore settingsStore;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settingsStore = await AppSettingsStore.create();
    db = createTestDatabase();
    secure = InMemorySecureStore();
    api = _FakeApi();
    final id = await db.insertAccount(
      AccountsCompanion.insert(
        email: 'a@example.com',
        username: 'a@example.com',
        imapHost: 'mail.example.com',
        smtpHost: 'mail.example.com',
      ),
    );
    await secure.writePassword(id, 'sifre');
  });

  tearDown(() async {
    await db.close();
  });

  ProviderContainer makeContainer(_FakeTokenSource source) {
    final container = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(settingsStore),
        allAccountsProvider.overrideWith((ref) => db.watchAllAccounts()),
        pushTokenSourceProvider.overrideWithValue(source),
        remotePushSyncProvider.overrideWithValue(
          RemotePushSync(
            api: api,
            store: _MemoryStore(),
            readPassword: secure.readPassword,
            environment: 'production',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// Durum [expected] olana kadar bekler (en çok ~2 sn).
  Future<void> expectState(
    ProviderContainer container,
    ServerPushState expected,
  ) async {
    for (var i = 0; i < 100; i++) {
      if (container.read(remotePushControllerProvider) == expected) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(container.read(remotePushControllerProvider), expected);
  }

  test('token varsa hesaplar kaydedilir ve durum active olur', () async {
    final container = makeContainer(_FakeTokenSource('t' * 150));
    container.listen(remotePushControllerProvider, (_, _) {});

    await expectState(container, ServerPushState.active);
    expect(api.upserted, hasLength(1));
    expect(api.upserted.single.pushToken, 't' * 150);
  });

  test('token alınamazsa durum unavailable olur (yedek servis çalışır)', () async {
    final container = makeContainer(_FakeTokenSource(null));
    container.listen(remotePushControllerProvider, (_, _) {});

    await expectState(container, ServerPushState.unavailable);
    expect(api.upserted, isEmpty);
  });

  test('sunucu hatasında durum failing olur', () async {
    api.fail = true;
    final container = makeContainer(_FakeTokenSource('t' * 150));
    container.listen(remotePushControllerProvider, (_, _) {});

    await expectState(container, ServerPushState.failing);
  });

  test('bildirimler kapalıysa durum disabled olur', () async {
    await settingsStore.write(
      settingsStore.read().copyWith(notificationsEnabled: false),
    );
    final container = makeContainer(_FakeTokenSource('t' * 150));
    container.listen(remotePushControllerProvider, (_, _) {});

    await expectState(container, ServerPushState.disabled);
    expect(api.upserted, isEmpty);
  });

  test('token yenilenince yeni token ile yeniden kaydedilir', () async {
    final source = _FakeTokenSource('a' * 150);
    final container = makeContainer(source);
    container.listen(remotePushControllerProvider, (_, _) {});
    await expectState(container, ServerPushState.active);

    source.controller.add('b' * 150);
    for (var i = 0; i < 100 && api.upserted.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(api.upserted.last.pushToken, 'b' * 150);
  });
}
