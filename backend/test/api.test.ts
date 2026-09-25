import { beforeEach, describe, expect, it, vi } from 'vitest';
import { buildApp, type AccountHooks } from '../src/app.js';
import { SecretBox } from '../src/crypto.js';
import { openDatabase } from '../src/db.js';
import { Repository } from '../src/repository.js';

const API_KEY = 'k'.repeat(40);
const TOKEN = 'ab'.repeat(32);
const auth = { authorization: `Bearer ${API_KEY}` };

const body = (over: Record<string, unknown> = {}) => ({
  apnsToken: TOKEN,
  environment: 'development',
  clientAccountId: 1,
  imap: { host: 'imap.example.com', port: 993, secure: true },
  username: 'me@example.com',
  password: 'hunter2',
  ...over,
});

function setup() {
  const db = openDatabase(':memory:');
  const repo = new Repository(db, new SecretBox('c'.repeat(64)));
  const hooks: AccountHooks = {
    onAccountUpserted: vi.fn(),
    onAccountsRemoved: vi.fn(),
  };
  return { db, repo, hooks, app: buildApp({ repo, apiKey: API_KEY, hooks }) };
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
      headers: { authorization: 'Bearer yanlis' },
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
});
