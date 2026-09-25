import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/app/providers.dart';
import 'package:kaydet/app/remote_push_controller.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/remote_push_sync.dart';
import 'package:kaydet/data/services/app_settings.dart';
import 'package:kaydet/data/services/push_backend_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/test_db.dart';

class _MemoryStore implements RegistrationStore {
  RegistrationSnapshot snapshot = const RegistrationSnapshot();

  @override
  RegistrationSnapshot read() => snapshot;

  @override
  Future<void> write(RegistrationSnapshot value) async => snapshot = value;
}

class _RecordingApi implements RemotePushApi {
  final List<String> calls = [];
  final List<String> passwords = [];

  @override
  Future<void> upsertAccount(RemotePushAccount account) async {
    calls.add('upsert:${account.clientAccountId}');
    passwords.add(account.password);
  }

  @override
  Future<void> deleteAccount({
    required String apnsToken,
    required int clientAccountId,
  }) async => calls.add('deleteAccount:$clientAccountId');

  @override
  Future<void> deleteDevice(String apnsToken) async =>
      calls.add('deleteDevice');
}

void main() {
  late AppDatabase db;
  late _RecordingApi api;
  late StreamController<String> tokens;
  late StreamController<List<AccountRow>> accountsStream;
  late Map<int, String?> passwords;

  setUp(() {
    db = createTestDatabase();
    api = _RecordingApi();
    tokens = StreamController<String>.broadcast();
    accountsStream = StreamController<List<AccountRow>>.broadcast();
    passwords = {};
  });

  tearDown(() async {
    await tokens.close();
    await accountsStream.close();
    await db.close();
  });

  Future<AccountRow> addAccount(String email) async {
    final id = await db.insertAccount(
      AccountsCompanion.insert(
        email: email,
        username: email,
        imapHost: 'imap.example.com',
        smtpHost: 'imap.example.com',
        displayName: Value(email),
      ),
    );
    passwords[id] = 'pw-$id';
    return (await db.allAccounts()).firstWhere((a) => a.id == id);
  }

  Future<ProviderContainer> start({
    required bool remotePush,
    required List<AccountRow> accounts,
    RemotePushSync? syncOverride,
    bool syncAvailable = true,
  }) async {
    SharedPreferences.setMockInitialValues({
      'kaydet.remotePushEnabled': remotePush,
      'kaydet.notifications': true,
    });
    final prefs = await SharedPreferences.getInstance();
    final sync =
        syncOverride ??
        RemotePushSync(
          api: api,
          store: _MemoryStore(),
          readPassword: (id) async => passwords[id],
          environment: 'development',
        );
    final container = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(AppSettingsStore(prefs)),
        remotePushSyncProvider.overrideWithValue(syncAvailable ? sync : null),
        apnsTokenSourceProvider.overrideWithValue((
          latest: null,
          stream: tokens.stream,
        )),
        allAccountsProvider.overrideWith((ref) async* {
          yield accounts;
          yield* accountsStream.stream;
        }),
      ],
    );
    addTearDown(container.dispose);
    // Sağlayıcıları canlı tut (uygulamada `main.dart` izler).
    container.listen(remotePushControllerProvider, (_, _) {});
    container.listen(allAccountsProvider, (_, _) {});
    await container.read(allAccountsProvider.future);
    return container;
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  test('token gelince hesapları sunucuya kaydeder', () async {
    final a = await addAccount('a@x.com');
    await start(remotePush: true, accounts: [a]);

    expect(api.calls, isEmpty); // token yok: bekler
    tokens.add('aa');
    await settle();
    expect(api.calls, ['upsert:${a.id}']);
  });

  test('kullanıcı onayı yoksa (ayar kapalı) hiçbir şey göndermez', () async {
    final a = await addAccount('a@x.com');
    await start(remotePush: false, accounts: [a]);

    tokens.add('aa');
    await settle();
    expect(api.calls, isEmpty);
  });

  test(
    'yapılandırma yoksa (sağlayıcı null) özellik tümüyle etkisizdir',
    () async {
      final a = await addAccount('a@x.com');
      await start(remotePush: true, accounts: [a], syncAvailable: false);

      tokens.add('aa');
      await settle();
      expect(api.calls, isEmpty);
    },
  );

  test('yeni hesap eklenince ve silinince sunucu güncellenir', () async {
    final a = await addAccount('a@x.com');
    await start(remotePush: true, accounts: [a]);
    tokens.add('aa');
    await settle();
    api.calls.clear();

    final b = await addAccount('b@x.com');
    accountsStream.add([a, b]);
    await settle();
    expect(api.calls, ['upsert:${b.id}']);

    api.calls.clear();
    accountsStream.add([b]);
    await settle();
    expect(api.calls, ['deleteAccount:${a.id}']);
  });

  test('şifre değişince aynı hesap yeniden gönderilir', () async {
    final a = await addAccount('a@x.com');
    final container = await start(remotePush: true, accounts: [a]);
    tokens.add('aa');
    await settle();

    passwords[a.id] = 'yeni-sifre';
    container.read(remotePushControllerProvider.notifier).passwordChanged(a.id);
    await settle();

    expect(api.passwords, ['pw-${a.id}', 'yeni-sifre']);
  });
}
