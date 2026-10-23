import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/remote_push_sync.dart';
import 'package:kaydet/data/services/push_backend_client.dart';
import 'package:kaydet/data/services/secure_store.dart';

import 'helpers/test_db.dart';

class _FakeApi implements RemotePushApi {
  @override
  String baseUrl = 'https://test.example.com';

  final List<RemotePushAccount> upserted = [];
  final List<({String pushToken, int clientAccountId})> deletedAccounts = [];
  final List<String> deletedDevices = [];
  final Set<int> registeredAccountIds = {};

  /// Sunucunun hesap başına bildirdiği izleme durumu (varsayılan: izleniyor).
  final Map<int, ServerWatchStatus> statuses = {};
  Object? failWith;
  int listCalls = 0;

  @override
  Future<List<RegisteredAccount>> listRegisteredAccounts(
    String pushToken,
  ) async {
    listCalls++;
    if (failWith != null) throw failWith!;
    return [
      for (final id in registeredAccountIds)
        RegisteredAccount(id, statuses[id] ?? ServerWatchStatus.watching),
    ];
  }

  @override
  Future<void> upsertAccount(RemotePushAccount account) async {
    if (failWith != null) throw failWith!;
    upserted.add(account);
    registeredAccountIds.add(account.clientAccountId);
  }

  @override
  Future<void> deleteAccount({
    required String pushToken,
    required int clientAccountId,
  }) async {
    if (failWith != null) throw failWith!;
    deletedAccounts.add((pushToken: pushToken, clientAccountId: clientAccountId));
    registeredAccountIds.remove(clientAccountId);
    statuses.remove(clientAccountId);
  }

  @override
  Future<void> deleteDevice(String pushToken) async {
    if (failWith != null) throw failWith!;
    deletedDevices.add(pushToken);
    registeredAccountIds.clear();
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

  test('token değişince hesaplar yeni token ile gönderilir; eski cihaz SİLİNMEZ '
      '(sunucu hesapları yenisine taşır, izleyici/imleç korunur)', () async {
    final id = await addAccount('a@example.com');
    await secureStore.writePassword(id, 'sifre');
    final account = (await db.accountById(id))!;
    await sync.sync(token: token, enabled: true, accounts: [account]);

    final newToken = 'b'.padRight(64, 'b');
    final ok = await sync.sync(token: newToken, enabled: true, accounts: [account]);

    expect(ok, isTrue);
    expect(api.deletedDevices, isEmpty);
    expect(api.upserted.last.pushToken, newToken);
    expect(store.read().token, newToken);
  });

  test('token değişirken taşınacak hesap yoksa eski cihaz silinir', () async {
    final id = await addAccount('a@example.com');
    await secureStore.writePassword(id, 'sifre');
    final account = (await db.accountById(id))!;
    await sync.sync(token: token, enabled: true, accounts: [account]);

    final newToken = 'b'.padRight(64, 'b');
    final ok = await sync.sync(token: newToken, enabled: true, accounts: []);

    expect(ok, isTrue);
    expect(api.deletedDevices, [token]);
  });

  test('token değişiminde sunucunun taşıdığı, cihazdan silinmiş hesap yetim kalmaz', () async {
    final keep = await addAccount('a@example.com');
    await secureStore.writePassword(keep, 'sifre');
    final account = (await db.accountById(keep))!;
    await sync.sync(token: token, enabled: true, accounts: [account]);

    // Sunucu eski cihazın hesaplarını yenisine taşıdı; 99 telefondan çoktan silinmiş.
    api.registeredAccountIds.add(99);

    final newToken = 'b'.padRight(64, 'b');
    await sync.sync(token: newToken, enabled: true, accounts: [account]);

    expect(api.deletedAccounts.map((d) => d.clientAccountId), contains(99));
    expect(api.registeredAccountIds, {keep});
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

  test('sunucu sıfırlandığında yerel parmak izi olsa bile eksik hesaplar otomatik yeniden gönderilir', () async {
    final id1 = await addAccount('a@example.com');
    final id2 = await addAccount('b@example.com');
    await secureStore.writePassword(id1, 'sifre1');
    await secureStore.writePassword(id2, 'sifre2');
    final a1 = (await db.accountById(id1))!;
    final a2 = (await db.accountById(id2))!;

    // İlk eşitleme: her iki hesap da sunucuya kaydedilir
    await sync.sync(token: token, enabled: true, accounts: [a1, a2]);
    expect(api.registeredAccountIds, {id1, id2});
    expect(api.upserted, hasLength(2));

    // Sunucu tarafında veritabanı sıfırlandı (ör. redeploy), sunucu sadece id1'i hatırlıyor
    api.registeredAccountIds.remove(id2);
    api.upserted.clear();

    // İkinci eşitleme: telefon id2'nin sunucuda olmadığını fark edip yeniden gönderir
    final ok = await sync.sync(token: token, enabled: true, accounts: [a1, a2]);
    expect(ok, isTrue);
    expect(api.upserted, hasLength(1));
    expect(api.upserted.single.clientAccountId, id2);
    expect(api.registeredAccountIds, {id1, id2});
  });

  group('sunucunun gerçek izleme durumu', () {
    late DateTime clock;

    setUp(() {
      clock = DateTime(2026, 10, 23, 12);
      sync = RemotePushSync(
        api: api,
        store: store,
        readPassword: secureStore.readPassword,
        environment: 'development',
        now: () => clock,
      );
    });

    Future<List<AccountRow>> addFive() async {
      final rows = <AccountRow>[];
      for (var i = 1; i <= 5; i++) {
        final id = await addAccount('u$i@example.com');
        await secureStore.writePassword(id, 'sifre$i');
        rows.add((await db.accountById(id))!);
      }
      return rows;
    }

    test('5 hesap bağımsız kaydedilir; her biri kendi kimliği ve şifresiyle gider', () async {
      final accounts = await addFive();

      final result = await sync.reconcile(token: token, enabled: true, accounts: accounts);

      expect(result.ok, isTrue);
      expect(result.unhealthyAccountIds, isEmpty);
      expect(api.upserted.map((a) => a.clientAccountId), [for (final a in accounts) a.id]);
      expect(api.upserted.map((a) => a.password), [for (var i = 1; i <= 5; i++) 'sifre$i']);
      expect(api.upserted.every((a) => a.pushToken == token), isTrue);
    });

    test('bir hesabın kimliği sunucuda reddedilmişse yalnızca o hesap taze şifreyle yeniden kaydedilir', () async {
      final accounts = await addFive();
      await sync.sync(token: token, enabled: true, accounts: accounts);
      api.upserted.clear();
      final broken = accounts[2];
      api.statuses[broken.id] = ServerWatchStatus.authFailed;
      await secureStore.writePassword(broken.id, 'yeni-sifre');

      final result = await sync.reconcile(token: token, enabled: true, accounts: accounts);

      expect(result.ok, isTrue);
      expect(api.upserted, hasLength(1));
      expect(api.upserted.single.clientAccountId, broken.id);
      expect(api.upserted.single.password, 'yeni-sifre');
      expect(result.repairedAccountIds, {broken.id});
      // Yeni oturumun durumu henüz belirsiz: sağlıksız sayılmaz.
      expect(result.unhealthyAccountIds, isEmpty);
    });

    test('izleyicisi düşmüş (stopped) kayıt yeniden gönderilir', () async {
      final accounts = await addFive();
      await sync.sync(token: token, enabled: true, accounts: accounts);
      api.upserted.clear();
      api.statuses[accounts[0].id] = ServerWatchStatus.stopped;

      await sync.sync(token: token, enabled: true, accounts: accounts);

      expect(api.upserted.single.clientAccountId, accounts[0].id);
    });

    test('onarım en çok her 10 dakikada bir denenir; arada hesap sağlıksız raporlanır', () async {
      final accounts = await addFive();
      await sync.sync(token: token, enabled: true, accounts: accounts);
      api.upserted.clear();
      final broken = accounts[1];
      api.statuses[broken.id] = ServerWatchStatus.authFailed;

      await sync.sync(token: token, enabled: true, accounts: accounts); // onarım
      expect(api.upserted, hasLength(1));
      api.upserted.clear();

      clock = clock.add(const Duration(minutes: 3));
      final early = await sync.reconcile(token: token, enabled: true, accounts: accounts);
      expect(api.upserted, isEmpty, reason: 'sağlayıcıda hesap kilitlenmesin');
      expect(early.unhealthyAccountIds, {broken.id});

      clock = clock.add(RemotePushSync.repairGap);
      await sync.sync(token: token, enabled: true, accounts: accounts);
      expect(api.upserted.single.clientAccountId, broken.id);
    });

    test('ulaşılamayan (unreachable) hesap yeniden gönderilmez ama sağlıksız raporlanır', () async {
      final accounts = await addFive();
      await sync.sync(token: token, enabled: true, accounts: accounts);
      api.upserted.clear();
      api.statuses[accounts[4].id] = ServerWatchStatus.unreachable;

      final result = await sync.reconcile(token: token, enabled: true, accounts: accounts);

      expect(api.upserted, isEmpty);
      expect(result.unhealthyAccountIds, {accounts[4].id});
    });

    test('bağlanmakta olan (connecting) ve izlenen hesaplar sağlıklıdır', () async {
      final accounts = await addFive();
      await sync.sync(token: token, enabled: true, accounts: accounts);
      api.statuses[accounts[0].id] = ServerWatchStatus.connecting;

      final result = await sync.reconcile(token: token, enabled: true, accounts: accounts);

      expect(result.unhealthyAccountIds, isEmpty);
      expect(api.upserted, hasLength(5)); // yalnızca ilk kayıt; yeniden gönderim yok
    });

    test('şifresi olmayan hesap sağlıksız sayılmaz (hiçbir izleyici onu açamaz)', () async {
      final accounts = await addFive();
      await sync.sync(token: token, enabled: true, accounts: accounts);
      api.statuses[accounts[3].id] = ServerWatchStatus.authFailed;
      await secureStore.deletePassword(accounts[3].id);

      final result = await sync.reconcile(token: token, enabled: true, accounts: accounts);

      expect(result.unhealthyAccountIds, isEmpty);
    });

    test('bir hesabı silmek diğer 4 hesabın sunucu kaydına dokunmaz', () async {
      final accounts = await addFive();
      await sync.sync(token: token, enabled: true, accounts: accounts);
      api.upserted.clear();

      await sync.sync(token: token, enabled: true, accounts: accounts.sublist(1));

      expect(api.deletedAccounts.map((d) => d.clientAccountId), [accounts[0].id]);
      expect(api.upserted, isEmpty);
      expect(api.registeredAccountIds, {for (final a in accounts.sublist(1)) a.id});
    });

    test('sağlıksız hesaplar kalıcı saklanır (arka plan okuyabilsin); sunucuya ulaşılamazsa korunur; devre dışında silinir', () async {
      final accounts = await addFive();
      await sync.sync(token: token, enabled: true, accounts: accounts);
      api.statuses[accounts[1].id] = ServerWatchStatus.unreachable;

      await sync.sync(token: token, enabled: true, accounts: accounts);
      expect(store.read().unhealthy, {accounts[1].id});

      // Sunucu bir an yanıt vermese de son bilinen sağlık durumu silinmez.
      api.failWith = const PushBackendException(503);
      await sync.sync(token: token, enabled: true, accounts: accounts);
      expect(store.read().unhealthy, {accounts[1].id});

      // Hesap izlenmeye başlayınca listeden düşer.
      api.failWith = null;
      api.statuses[accounts[1].id] = ServerWatchStatus.watching;
      await sync.sync(token: token, enabled: true, accounts: accounts);
      expect(store.read().unhealthy, isEmpty);

      // Bildirimler kapatılınca (cihaz sunucudan silinir) durum da temizlenir.
      api.statuses[accounts[2].id] = ServerWatchStatus.unreachable;
      await sync.sync(token: token, enabled: true, accounts: accounts);
      expect(store.read().unhealthy, {accounts[2].id});
      await sync.sync(token: token, enabled: false, accounts: accounts);
      expect(store.read().unhealthy, isEmpty);
    });

    test('durum bildirmeyen eski sunucu (unknown) hiçbir onarımı tetiklemez', () async {
      final accounts = await addFive();
      await sync.sync(token: token, enabled: true, accounts: accounts);
      api.upserted.clear();
      for (final a in accounts) {
        api.statuses[a.id] = ServerWatchStatus.unknown;
      }

      final result = await sync.reconcile(token: token, enabled: true, accounts: accounts);

      expect(api.upserted, isEmpty);
      expect(result.unhealthyAccountIds, isEmpty);
    });
  });

  test('sunucu adresi (baseUrl) değişirse tüm hesaplar yeni sunucuya kaydedilir', () async {
    final id = await addAccount('a@example.com');
    await secureStore.writePassword(id, 'sifre');
    final account = (await db.accountById(id))!;

    await sync.sync(token: token, enabled: true, accounts: [account]);
    expect(api.upserted, hasLength(1));

    // Yeni sunucuya geçildi
    api.baseUrl = 'https://new-backend.example.com';
    api.registeredAccountIds.clear(); // yeni sunucu boş
    api.upserted.clear();

    final ok = await sync.sync(token: token, enabled: true, accounts: [account]);
    expect(ok, isTrue);
    expect(api.upserted, hasLength(1));
    expect(api.upserted.single.clientAccountId, id);
  });
}
