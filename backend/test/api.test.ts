import { beforeEach, describe, expect, it, vi } from 'vitest';
import { buildApp, type AccountHooks } from '../src/app.js';
import { SecretBox } from '../src/crypto.js';
import { openDatabase } from '../src/db.js';
import { InstallRegistry } from '../src/installs.js';
import { Repository } from '../src/repository.js';

const API_KEY = 'k'.repeat(40);
const TOKEN = 'ab'.repeat(32);
const INSTALL = { 'x-install-id': 'a'.repeat(32), 'x-install-secret': 'b'.repeat(64) };
const auth = { authorization: `Bearer ${API_KEY}`, ...INSTALL };

const body = (over: Record<string, unknown> = {}) => ({
  apnsToken: TOKEN,
  environment: 'development',
  clientAccountId: 1,
  imap: { host: 'imap.example.com', port: 993, secure: true },
  username: 'me@example.com',
  password: 'hunter2',
  ...over,
});

function setup(androidPush = false) {
  const db = openDatabase(':memory:');
  const repo = new Repository(db, new SecretBox('c'.repeat(64)));
  const hooks: AccountHooks = {
    onAccountUpserted: vi.fn(),
    onAccountsRemoved: vi.fn(),
  };
  return { db, repo, hooks, app: buildApp({ repo, installs: new InstallRegistry(db), apiKey: API_KEY, hooks, androidPush }) };
}

describe('API', () => {
  let s: ReturnType<typeof setup>;
  const put = (payload: object) =>
    s.app.inject({ method: 'PUT', url: '/v1/accounts', headers: auth, payload });

  beforeEach(() => {
    s = setup();
  });

  it('/health kimlik doğrulaması istemez', async () => {
    const res = await s.app.inject({ method: 'GET', url: '/health' });
    expect(res.statusCode).toBe(200);
  });

  it('API anahtarı yoksa ya da yanlışsa 401', async () => {
    const none = await s.app.inject({
      method: 'PUT',
      url: '/v1/accounts',
      payload: body(),
    });
    const bad = await s.app.inject({
      method: 'PUT',
      url: '/v1/accounts',
      headers: { authorization: 'Bearer yanlis', ...INSTALL },
      payload: body(),
    });
    expect(none.statusCode).toBe(401);
    expect(bad.statusCode).toBe(401);
    expect(s.repo.listAccounts()).toHaveLength(0);
  });

  it('hesabı kaydeder, şifreyi şifreli saklar ve hook çağırır', async () => {
    const res = await put(body());
    expect(res.statusCode).toBe(204);
    const [row] = s.repo.listAccounts();
    expect(row!.password_enc).not.toContain('hunter2');
    expect(s.repo.decryptPassword(row!)).toBe('hunter2');
    expect(s.hooks.onAccountUpserted).toHaveBeenCalledOnce();
  });

  it('aynı hesabı tekrar göndermek günceller, çoğaltmaz', async () => {
    await put(body());
    await put(body({ password: 'yeni' }));
    const rows = s.repo.listAccounts();
    expect(rows).toHaveLength(1);
    expect(s.repo.decryptPassword(rows[0]!)).toBe('yeni');
  });

  it('sunucu değişince last_uid sıfırlanır, aynıysa korunur', async () => {
    await put(body());
    s.db.prepare('UPDATE accounts SET last_uid = 42').run();
    await put(body({ password: 'x' }));
    expect(s.repo.listAccounts()[0]!.last_uid).toBe(42);
    await put(
      body({ imap: { host: 'baska.example.com', port: 993, secure: true } }),
    );
    expect(s.repo.listAccounts()[0]!.last_uid).toBeNull();
  });

  it('geçersiz gövdeyi 400 ile reddeder', async () => {
    const res = await put(body({ apnsToken: 'kisa' }));
    expect(res.statusCode).toBe(400);
  });

  it('hesabı siler ve hook çağırır; olmayan hesap sessizce 204', async () => {
    await put(body());
    const id = s.repo.listAccounts()[0]!.id;
    const del = () =>
      s.app.inject({
        method: 'DELETE',
        url: '/v1/accounts',
        headers: auth,
        payload: { apnsToken: TOKEN, clientAccountId: 1 },
      });
    expect((await del()).statusCode).toBe(204);
    expect(s.repo.listAccounts()).toHaveLength(0);
    expect(s.hooks.onAccountsRemoved).toHaveBeenCalledWith([id]);
    expect((await del()).statusCode).toBe(204);
  });

  it('cihazı silince tüm hesapları gider', async () => {
    await put(body({ clientAccountId: 1 }));
    await put(body({ clientAccountId: 2 }));
    const ids = s.repo.listAccounts().map((a) => a.id);
    const res = await s.app.inject({
      method: 'DELETE',
      url: '/v1/devices',
      headers: auth,
      payload: { apnsToken: TOKEN },
    });
    expect(res.statusCode).toBe(204);
    expect(s.repo.listAccounts()).toHaveLength(0);
    expect(s.hooks.onAccountsRemoved).toHaveBeenCalledWith(ids);
  });

  it('cihazın kayıtlı hesap kimliklerini döner (GET /v1/accounts)', async () => {
    // Başlangıçta boş
    const emptyRes = await s.app.inject({
      method: 'GET',
      url: `/v1/accounts?apnsToken=${TOKEN}`,
      headers: auth,
    });
    expect(emptyRes.statusCode).toBe(200);
    expect(emptyRes.json()).toEqual({ clientAccountIds: [] });

    // 2 hesap ekle
    await put(body({ clientAccountId: 101 }));
    await put(body({ clientAccountId: 102 }));

    const res = await s.app.inject({
      method: 'GET',
      url: `/v1/accounts?apnsToken=${TOKEN}`,
      headers: auth,
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ clientAccountIds: [101, 102] });

    // Geçersiz token ile 400
    const badRes = await s.app.inject({
      method: 'GET',
      url: '/v1/accounts?apnsToken=kisa',
      headers: auth,
    });
    expect(badRes.statusCode).toBe(400);
  });

  describe('Android (FCM)', () => {
    const FCM = 'f'.repeat(30) + ':' + 'A'.repeat(120);
    const androidBody = (over: Record<string, unknown> = {}) => {
      const { apnsToken: _omit, ...rest } = body();
      return { ...rest, pushToken: FCM, platform: 'android', ...over };
    };

    it('FCM yapılandırılmamışsa 503 android_push_unavailable döner', async () => {
      const res = await put(androidBody());
      expect(res.statusCode).toBe(503);
      expect(res.json().error).toBe('android_push_unavailable');
      expect(s.hooks.onAccountUpserted).not.toHaveBeenCalled();
    });

    it('yapılandırılmışsa Android cihazı platformuyla kaydeder', async () => {
      const a = setup(true);
      const res = await a.app.inject({
        method: 'PUT', url: '/v1/accounts', headers: auth, payload: androidBody(),
      });
      expect(res.statusCode).toBe(204);
      const row = a.db.prepare('SELECT push_token, platform, environment FROM devices').get();
      expect(row).toEqual({ push_token: FCM, platform: 'android', environment: 'production' });
    });

    it('FCM token ı büyük/küçük harf korunarak saklanır; iOS token ı küçültülür', async () => {
      const a = setup(true);
      await a.app.inject({ method: 'PUT', url: '/v1/accounts', headers: auth, payload: androidBody() });
      await a.app.inject({
        method: 'PUT', url: '/v1/accounts', headers: auth,
        payload: body({ apnsToken: 'AB'.repeat(32), clientAccountId: 2 }),
      });
      const tokens = (a.db.prepare('SELECT push_token FROM devices ORDER BY id').all() as any[]).map((r) => r.push_token);
      expect(tokens).toEqual([FCM, 'ab'.repeat(32)]);
    });

    it('biçimi platforma göre doğrular', async () => {
      const a = setup(true);
      const hexForAndroid = await a.app.inject({
        method: 'PUT', url: '/v1/accounts', headers: auth, payload: androidBody({ pushToken: TOKEN }),
      });
      const fcmForIos = await a.app.inject({
        method: 'PUT', url: '/v1/accounts', headers: auth, payload: body({ apnsToken: undefined, pushToken: FCM }),
      });
      expect(hexForAndroid.statusCode).toBe(400);
      expect(fcmForIos.statusCode).toBe(400);
    });

    it('pushToken ile iOS kaydı, eski apnsToken ile aynı cihaza düşer', async () => {
      await put(body());
      const res = await s.app.inject({
        method: 'GET', url: `/v1/accounts?pushToken=${TOKEN}&platform=ios`, headers: auth,
      });
      expect(res.json()).toEqual({ clientAccountIds: [1] });
    });

    it('Android cihazı pushToken ile listelenir ve silinir', async () => {
      const a = setup(true);
      await a.app.inject({ method: 'PUT', url: '/v1/accounts', headers: auth, payload: androidBody() });
      const list = await a.app.inject({
        method: 'GET', url: `/v1/accounts?pushToken=${FCM}&platform=android`, headers: auth,
      });
      expect(list.json()).toEqual({ clientAccountIds: [1] });
      const del = await a.app.inject({
        method: 'DELETE', url: '/v1/devices', headers: auth, payload: { pushToken: FCM, platform: 'android' },
      });
      expect(del.statusCode).toBe(204);
      expect(a.db.prepare('SELECT COUNT(*) AS n FROM devices').get()).toEqual({ n: 0 });
    });
  });
});
