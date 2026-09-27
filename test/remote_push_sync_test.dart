import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/remote_push_sync.dart';
import 'package:kaydet/data/services/push_backend_client.dart';
import 'package:kaydet/data/services/secure_store.dart';

import 'helpers/test_db.dart';

class _FakeApi implements RemotePushApi {
  final List<RemotePushAccount> upserted = [];
  final List<({String apnsToken, int clientAccountId})> deletedAccounts = [];
  final List<String> deletedDevices = [];
  Object? failWith;

  @override
  Future<void> upsertAccount(RemotePushAccount account) async {
    if (failWith != null) throw failWith!;
    upserted.add(account);
  }

  @override
  Future<void> deleteAccount({
    required String apnsToken,
    required int clientAccountId,
  }) async {
    if (failWith != null) throw failWith!;
    deletedAccounts.add((apnsToken: apnsToken, clientAccountId: clientAccountId));
  }

  @override
  Future<void> deleteDevice(String apnsToken) async {
    if (failWith != null) throw failWith!;
    deletedDevices.add(apnsToken);
  }
}

class _InMemoryRegistrationStore implements RegistrationStore {
  RegistrationSnapshot _snapshot = const RegistrationSnapshot();

  @override
  RegistrationSnapshot read() => _snapshot;

  @override
  Future<void> write(RegistrationSnapshot snapshot) async {
    _snapshot = snapshot;
  }
}

/// `RemotePushSync`in cihaz kayıtlarını (yalnızca değişeni) push backend'e
/// eşleme mantığı — token/hesap parmak izi karşılaştırması, etkinleştirme/
/// devre dışı bırakma ve şifre değişiminde zorunlu yeniden gönderim.
void main() {
  late AppDatabase db;
  late InMemorySecureStore secureStore;
  late _FakeApi api;
  late _InMemoryRegistrationStore store;
  late RemotePushSync sync;

  final token = 'a'.padRight(64, 'a');

  Future<int> addAccount(String email) => db.insertAccount(
    AccountsCompanion.insert(
      email: email,
      username: email,
      imapHost: 'mail.example.com',
      smtpHost: 'mail.example.com',
    ),
  );

  setUp(() async {
    db = createTestDatabase();
    secureStore = InMemorySecureStore();
    api = _FakeApi();
    store = _InMemoryRegistrationStore();
    sync = RemotePushSync(
      api: api,
      store: store,
      readPassword: secureStore.readPassword,
      environment: 'development',
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('token yoksa hiçbir şey yapmaz', () async {
    final id = await addAccount('a@example.com');
    await secureStore.writePassword(id, 'sifre');

    final ok = await sync.sync(
      token: null,
      enabled: true,
      accounts: [(await db.accountById(id))!],
    );

    expect(ok, isTrue);
    expect(api.upserted, isEmpty);
  });

  test('yeni hesabı kaydeder ve parmak izini saklar', () async {
    final id = await addAccount('a@example.com');
    await secureStore.writePassword(id, 'sifre');
    final account = (await db.accountById(id))!;

    final ok = await sync.sync(token: token, enabled: true, accounts: [account]);

    expect(ok, isTrue);
    expect(api.upserted, hasLength(1));
    expect(api.upserted.single.clientAccountId, id);
    expect(api.upserted.single.password, 'sifre');
    expect(store.read().fingerprints[id], sync.fingerprint(token, account));
  });

  test('parmak izi değişmediyse tekrar göndermez', () async {
    final id = await addAccount('a@example.com');
    await secureStore.writePassword(id, 'sifre');
    final account = (await db.accountById(id))!;

    await sync.sync(token: token, enabled: true, accounts: [account]);
    await sync.sync(token: token, enabled: true, accounts: [account]);

    expect(api.upserted, hasLength(1));
  });

  test('şifresi olmayan hesap atlanır', () async {
    final id = await addAccount('a@example.com');
    final account = (await db.accountById(id))!;

    final ok = await sync.sync(token: token, enabled: true, accounts: [account]);

    expect(ok, isTrue);
    expect(api.upserted, isEmpty);
  });

  test('force verilirse parmak izi aynı olsa da yeniden gönderir', () async {
    final id = await addAccount('a@example.com');
    await secureStore.writePassword(id, 'eski');
    final account = (await db.accountById(id))!;
    await sync.sync(token: token, enabled: true, accounts: [account]);

    await secureStore.writePassword(id, 'yeni');
    await sync.sync(
      token: token,
      enabled: true,
      accounts: [account],
      force: {id},
    );

    expect(api.upserted, hasLength(2));
    expect(api.upserted.last.password, 'yeni');
  });

  test('artık cihazda olmayan hesap sunucudan silinir', () async {
    final id = await addAccount('a@example.com');
    await secureStore.writePassword(id, 'sifre');
    final account = (await db.accountById(id))!;
    await sync.sync(token: token, enabled: true, accounts: [account]);

    final ok = await sync.sync(token: token, enabled: true, accounts: []);

    expect(ok, isTrue);
    expect(api.deletedAccounts, hasLength(1));
    expect(api.deletedAccounts.single.clientAccountId, id);
    expect(store.read().fingerprints, isEmpty);
  });

  test('devre dışı bırakılınca cihaz sunucudan silinir', () async {
    final id = await addAccount('a@example.com');
    await secureStore.writePassword(id, 'sifre');
    final account = (await db.accountById(id))!;
    await sync.sync(token: token, enabled: true, accounts: [account]);

    final ok = await sync.sync(token: token, enabled: false, accounts: [account]);

    expect(ok, isTrue);
    expect(api.deletedDevices, [token]);
    expect(store.read().token, isNull);
    expect(store.read().fingerprints, isEmpty);
  });

  test('token değişince eski cihaz silinir, hesaplar yeni token ile gönderilir', () async {
    final id = await addAccount('a@example.com');
    await secureStore.writePassword(id, 'sifre');
    final account = (await db.accountById(id))!;
    await sync.sync(token: token, enabled: true, accounts: [account]);

    final newToken = 'b'.padRight(64, 'b');
    final ok = await sync.sync(token: newToken, enabled: true, accounts: [account]);

    expect(ok, isTrue);
    expect(api.deletedDevices, [token]);
    expect(api.upserted.last.apnsToken, newToken);
    expect(store.read().token, newToken);
  });

  test('sunucu hatasında false döner, kayıt durumu bozulmaz', () async {
    final id = await addAccount('a@example.com');
    await secureStore.writePassword(id, 'sifre');
    final account = (await db.accountById(id))!;
    api.failWith = const PushBackendException(500);

    final ok = await sync.sync(token: token, enabled: true, accounts: [account]);

    expect(ok, isFalse);
    expect(store.read().fingerprints, isEmpty);
  });
}
