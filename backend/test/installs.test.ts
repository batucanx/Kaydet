import { describe, expect, it, vi } from 'vitest';
import { buildApp } from '../src/app.js';
import { SecretBox } from '../src/crypto.js';
import { openDatabase } from '../src/db.js';
import { InstallRegistry } from '../src/installs.js';
import { Repository } from '../src/repository.js';

const API_KEY = 'k'.repeat(40);
const TOKEN = 'ab'.repeat(32);
const hdr = (id: string, secret: string) => ({
  authorization: `Bearer ${API_KEY}`,
  'x-install-id': id,
  'x-install-secret': secret,
});
const A = hdr('a'.repeat(32), 'b'.repeat(64));

const account = (n: number) => ({
  apnsToken: TOKEN,
  environment: 'development',
  clientAccountId: n,
  imap: { host: 'imap.example.com', port: 993, secure: true },
  username: 'me@example.com',
  password: 'pw',
});

function setup(opts: { perHour?: number; maxAccounts?: number; now?: () => number } = {}) {
  const db = openDatabase(':memory:');
  const repo = new Repository(db, new SecretBox('c'.repeat(64)), opts.maxAccounts);
  const installs = new InstallRegistry(db, {
    newInstallsPerHour: opts.perHour ?? 30,
    now: opts.now,
  });
  const app = buildApp({
    repo,
    installs,
    apiKey: API_KEY,
    hooks: { onAccountUpserted: vi.fn(), onAccountsRemoved: vi.fn() },
  });
  return { db, repo, app };
}

const put = (
  s: ReturnType<typeof setup>,
  headers: Record<string, string>,
  n = 1,
  apnsToken = TOKEN,
) =>
  s.app.inject({
    method: 'PUT',
    url: '/v1/accounts',
    headers,
    payload: { ...account(n), apnsToken },
  });

describe('kurulum doğrulaması', () => {
  it('kurulum başlıkları yoksa ya da biçimsiz ise 401 install_required', async () => {
    const s = setup();
    const bare = { authorization: `Bearer ${API_KEY}` };
    expect((await put(s, bare)).json()).toEqual({ error: 'install_required' });
    expect((await put(s, hdr('kisa', 'b'.repeat(64)))).statusCode).toBe(401);
    expect((await put(s, hdr('a'.repeat(32), 'ZZ'))).statusCode).toBe(401);
    expect(s.repo.listAccounts()).toHaveLength(0);
  });

  it('ilk görüşte kaydeder, sonra yanlış sırrı 401 install_invalid ile reddeder', async () => {
    const s = setup();
    expect((await put(s, A)).statusCode).toBe(204);
    expect((await put(s, A, 2)).statusCode).toBe(204);
    const wrong = await put(s, hdr('a'.repeat(32), 'c'.repeat(64)), 3);
    expect(wrong.statusCode).toBe(401);
    expect(wrong.json()).toEqual({ error: 'install_invalid' });
  });

  it('sırrı düz saklamaz', () => {
    const s = setup();
    return put(s, A).then(() => {
      const row = s.db.prepare('SELECT secret_hash FROM installs').get() as { secret_hash: string };
      expect(row.secret_hash).not.toContain('b'.repeat(64));
      expect(row.secret_hash).toHaveLength(64);
    });
  });

  it('cihaz satırına kurulum kimliği yazılır', async () => {
    const s = setup();
    await put(s, A);
    const d = s.db.prepare('SELECT install_id FROM devices').get() as { install_id: string };
    expect(d.install_id).toBe('a'.repeat(32));
  });

  it('IP başına saatlik yeni kurulum sınırı; mevcut kurulum etkilenmez; pencere dolunca açılır', async () => {
    let now = 1_000_000;
    const s = setup({ perHour: 2, now: () => now });
    expect((await put(s, hdr('1'.repeat(32), 'b'.repeat(64)))).statusCode).toBe(204);
    expect((await put(s, hdr('2'.repeat(32), 'b'.repeat(64)))).statusCode).toBe(204);
    const third = await put(s, hdr('3'.repeat(32), 'b'.repeat(64)));
    expect(third.statusCode).toBe(429);
    expect(third.json()).toEqual({ error: 'install_rate_limited' });
    expect((await put(s, hdr('1'.repeat(32), 'b'.repeat(64)), 2)).statusCode).toBe(204);
    now += 3_600_001;
    expect((await put(s, hdr('3'.repeat(32), 'b'.repeat(64)))).statusCode).toBe(204);
  });

  it('kurulum başına hesap sınırı aşılınca 429; mevcut hesap güncellenebilir', async () => {
    const s = setup({ maxAccounts: 2 });
    expect((await put(s, A, 1)).statusCode).toBe(204);
    expect((await put(s, A, 2)).statusCode).toBe(204);
    const over = await put(s, A, 3);
    expect(over.statusCode).toBe(429);
    expect(over.json()).toEqual({ error: 'install_account_limit' });
    expect((await put(s, A, 2)).statusCode).toBe(204);
    // Başka kurulumun sınırı ayrıdır.
    expect((await put(s, hdr('d'.repeat(32), 'e'.repeat(64)), 1, 'cd'.repeat(32))).statusCode).toBe(204);
  });

  it('çeviri kotası istemcinin gönderdiği userId değil, doğrulanmış kuruluma bağlanır', async () => {
    const calls: string[] = [];
    const db = openDatabase(':memory:');
    const app = buildApp({
      repo: new Repository(db, new SecretBox('c'.repeat(64))),
      installs: new InstallRegistry(db),
      apiKey: API_KEY,
      translation: {
        translate: async (i: { userId: string }) => {
          calls.push(i.userId);
          return { ok: false, status: 503, code: 'TRANSLATION_UNAVAILABLE' };
        },
      } as never,
    });
    for (const userId of ['rastgele-kimlik-1', 'rastgele-kimlik-2']) {
      await app.inject({
        method: 'POST',
        url: '/v1/translate',
        headers: A,
        payload: {
          userId,
          messageId: '1',
          sourceLanguage: 'auto',
          targetLanguage: 'tr',
          subject: 'x',
          segments: ['y'],
        },
      });
    }
    expect(calls).toEqual(['a'.repeat(32), 'a'.repeat(32)]);
  });
});

describe('veritabanı geçişi', () => {
  it('install_id sütunu olmayan eski devices tablosuna eklenir', async () => {
    const { mkdtempSync } = await import('node:fs');
    const { tmpdir } = await import('node:os');
    const { join } = await import('node:path');
    const Database = (await import('better-sqlite3')).default;
    const path = join(mkdtempSync(join(tmpdir(), 'kaydet-')), 'eski.sqlite');
    const old = new Database(path);
    old.exec(`CREATE TABLE devices (
      id INTEGER PRIMARY KEY AUTOINCREMENT, apns_token TEXT NOT NULL UNIQUE,
      environment TEXT NOT NULL, created_at INTEGER NOT NULL);
      INSERT INTO devices (apns_token, environment, created_at) VALUES ('t','production',1);`);
    old.close();
    const db = openDatabase(path);
    const cols = (db.prepare('PRAGMA table_info(devices)').all() as { name: string }[]).map((c) => c.name);
    expect(cols).toContain('install_id');
    expect(cols).toContain('push_token');
    expect(cols).not.toContain('apns_token');
    // Eski satırların tümü iOS'tur ve token'ı korunur.
    expect(db.prepare('SELECT install_id, platform, push_token FROM devices').get()).toEqual({
      install_id: null,
      platform: 'ios',
      push_token: 't',
    });
    db.close();
  });
});
