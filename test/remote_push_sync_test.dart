import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:kaydet/data/database/app_database.dart';
import 'package:kaydet/data/repositories/remote_push_sync.dart';
import 'package:kaydet/data/services/push_backend_client.dart';
import 'package:kaydet/domain/models/mail_models.dart';

import 'helpers/test_db.dart';

class _MemoryStore implements RegistrationStore {
  RegistrationSnapshot snapshot = const RegistrationSnapshot();

  @override
  RegistrationSnapshot read() => snapshot;

  @override
  Future<void> write(RegistrationSnapshot value) async => snapshot = value;
}

class _FakeApi implements RemotePushApi {
  final List<String> calls = [];
  final List<RemotePushAccount> upserts = [];

  /// Doluysa sıradaki çağrılar bu hatalarla düşer.
  final List<Object> failures = [];

  void _maybeFail() {
    if (failures.isNotEmpty) throw failures.removeAt(0);
  }

  @override
  Future<void> upsertAccount(RemotePushAccount account) async {
    _maybeFail();
    calls.add('upsert:${account.clientAccountId}');
    upserts.add(account);
  }

  @override
  Future<void> deleteAccount({
    required String apnsToken,
    required int clientAccountId,
  }) async {
    _maybeFail();
    calls.add('deleteAccount:$clientAccountId');
  }

  @override
  Future<void> deleteDevice(String apnsToken) async {
    _maybeFail();
    calls.add('deleteDevice:$apnsToken');
  }
}

void main() {
  late AppDatabase db;
  late _FakeApi api;
  late _MemoryStore store;
  late Map<int, String?> passwords;
  late RemotePushSync sync;

  const token = 'aa';
  const otherToken = 'bb';

  setUp(() {
    db = createTestDatabase();
    api = _FakeApi();
    store = _MemoryStore();
    passwords = {};
    sync = RemotePushSync(
      api: api,
      store: store,
      readPassword: (id) async => passwords[id],
      environment: 'development',
    );
  });

  tearDown(() => db.close());

  Future<AccountRow> addAccount(
    String email, {
    String host = 'imap.example.com',
    SocketSecurity security = SocketSecurity.ssl,
    String password = 'pw',
  }) async {
    final id = await db.insertAccount(
      AccountsCompanion.insert(
        email: email,
        username: email,
        imapHost: host,
        smtpHost: host,
        imapSecurity: Value(security),
      ),
    );
    passwords[id] = password;
    return (await db.allAccounts()).firstWhere((a) => a.id == id);
  }

  test('token yoksa hiçbir şey göndermez', () async {
    final a = await addAccount('a@x.com');
    final ok = await sync.sync(token: null, enabled: true, accounts: [a]);
    expect(ok, isTrue);
    expect(api.calls, isEmpty);
  });

  test('hesabı IMAP bilgileriyle kaydeder', () async {
    final a = await addAccount('a@x.com', security: SocketSecurity.startTls);
    final ok = await sync.sync(token: token, enabled: true, accounts: [a]);

    expect(ok, isTrue);
    final sent = api.upserts.single;
    expect(sent.apnsToken, token);
    expect(sent.environment, 'development');
    expect(sent.clientAccountId, a.id);
    expect(sent.host, 'imap.example.com');
    expect(sent.username, 'a@x.com');
    expect(sent.password, 'pw');
    // Yalnızca doğrudan TLS `secure` sayılır.
    expect(sent.secure, isFalse);
  });

  test(
    'değişmeyen hesabı tekrar göndermez (sunucudaki IDLE sıfırlanmasın)',
    () async {
      final a = await addAccount('a@x.com');
      await sync.sync(token: token, enabled: true, accounts: [a]);
      await sync.sync(token: token, enabled: true, accounts: [a]);
      expect(api.upserts, hasLength(1));
    },
  );

  test('sunucu ayarı değişince yeniden gönderir', () async {
    final a = await addAccount('a@x.com');
    await sync.sync(token: token, enabled: true, accounts: [a]);
    await db.updateAccountFields(
      a.id,
      const AccountsCompanion(imapHost: Value('imap2.example.com')),
    );
    final changed = (await db.allAccounts()).single;
    await sync.sync(token: token, enabled: true, accounts: [changed]);
    expect(api.upserts, hasLength(2));
    expect(api.upserts.last.host, 'imap2.example.com');
  });

  test('force ile aynı hesap yeniden gönderilir (şifre değişimi)', () async {
    final a = await addAccount('a@x.com');
    await sync.sync(token: token, enabled: true, accounts: [a]);
    passwords[a.id] = 'yeni';
    await sync.sync(token: token, enabled: true, accounts: [a], force: {a.id});
    expect(api.upserts.last.password, 'yeni');
  });

  test('silinen hesabı sunucudan da siler', () async {
    final a = await addAccount('a@x.com');
    final b = await addAccount('b@x.com');
    await sync.sync(token: token, enabled: true, accounts: [a, b]);
    api.calls.clear();

    await sync.sync(token: token, enabled: true, accounts: [b]);
    expect(api.calls, ['deleteAccount:${a.id}']);
    expect(store.snapshot.fingerprints.keys, [b.id]);
  });

  test(
    'token değişince eski cihazı siler, hesapları yeni token ile yazar',
    () async {
      final a = await addAccount('a@x.com');
      await sync.sync(token: token, enabled: true, accounts: [a]);
      api.calls.clear();

      await sync.sync(token: otherToken, enabled: true, accounts: [a]);
      expect(api.calls, ['deleteDevice:$token', 'upsert:${a.id}']);
      expect(api.upserts.last.apnsToken, otherToken);
      expect(store.snapshot.token, otherToken);
    },
  );

  test('kapatılınca cihazın tüm kaydını siler ve durumu temizler', () async {
    final a = await addAccount('a@x.com');
    await sync.sync(token: token, enabled: true, accounts: [a]);
    api.calls.clear();

    expect(
      await sync.sync(token: token, enabled: false, accounts: [a]),
      isTrue,
    );
    expect(api.calls, ['deleteDevice:$token']);
    expect(store.snapshot.token, isNull);
    expect(store.snapshot.fingerprints, isEmpty);

    // Kapalıyken tekrar tekrar sunucuya gitmez.
    api.calls.clear();
    await sync.sync(token: token, enabled: false, accounts: [a]);
    expect(api.calls, isEmpty);
  });

  test('kapatırken silme başarısızsa durum korunur ve false döner', () async {
    final a = await addAccount('a@x.com');
    await sync.sync(token: token, enabled: true, accounts: [a]);

    api.failures.add(const PushBackendException(503));
    expect(
      await sync.sync(token: token, enabled: false, accounts: [a]),
      isFalse,
    );
    expect(store.snapshot.token, token);
    expect(store.snapshot.fingerprints, isNotEmpty);

    // Sonraki denemede silinir.
    expect(
      await sync.sync(token: token, enabled: false, accounts: [a]),
      isTrue,
    );
    expect(store.snapshot.token, isNull);
  });

  test('ağ hatasında false döner, sonra kaldığı yerden devam eder', () async {
    final a = await addAccount('a@x.com');
    final b = await addAccount('b@x.com');
    api.failures.add(Exception('ağ yok'));

    expect(
      await sync.sync(token: token, enabled: true, accounts: [a, b]),
      isFalse,
    );
    expect(api.upserts, isEmpty); // ilk hatada durur, b için boşuna denemez

    expect(
      await sync.sync(token: token, enabled: true, accounts: [a, b]),
      isTrue,
    );
    expect(api.upserts.map((u) => u.clientAccountId), [a.id, b.id]);
  });

  test('sunucunun reddettiği hesap diğerlerini engellemez', () async {
    final a = await addAccount('a@x.com');
    final b = await addAccount('b@x.com');
    api.failures.add(const PushBackendException(400));

    expect(
      await sync.sync(token: token, enabled: true, accounts: [a, b]),
      isFalse,
    );
    expect(api.upserts.map((u) => u.clientAccountId), [b.id]);
  });

  test('yanlış API anahtarında (401) toplu denemeyi keser', () async {
    final a = await addAccount('a@x.com');
    final b = await addAccount('b@x.com');
    api.failures.add(const PushBackendException(401));

    expect(
      await sync.sync(token: token, enabled: true, accounts: [a, b]),
      isFalse,
    );
    expect(api.upserts, isEmpty);
  });

  test('şifresi olmayan hesap atlanır', () async {
    final a = await addAccount('a@x.com');
    passwords[a.id] = null;
    expect(await sync.sync(token: token, enabled: true, accounts: [a]), isTrue);
    expect(api.calls, isEmpty);
  });
}
