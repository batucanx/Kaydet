import type { FetchMessageObject } from 'imapflow';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { ApnsResult } from '../src/apns.js';
import { SecretBox } from '../src/crypto.js';
import { openDatabase } from '../src/db.js';
import { Notifier } from '../src/notifier.js';
import { Repository } from '../src/repository.js';
import { backoffDelay, describeMessage } from '../src/watcher.js';

const TOKEN = 'ab'.repeat(32);

function setup(results: ApnsResult[] = []) {
  const db = openDatabase(':memory:');
  const repo = new Repository(db, new SecretBox('c'.repeat(64)));
  const account = repo.upsertAccount({
    apnsToken: TOKEN,
    environment: 'development',
    clientAccountId: 7,
    host: 'imap.example.com',
    port: 993,
    secure: true,
    username: 'me@example.com',
    password: 'pw',
  });
  const send = vi.fn(async () => results.shift() ?? ({ status: 'sent' } as ApnsResult));
  const removed = vi.fn();
  const notifier = new Notifier(repo, { send }, {
    onDevicesRemoved: removed,
    sleep: async () => {},
  });
  return { repo, account, send, removed, notifier };
}

const msg = (uid: number, fromName = 'Ali', subject = 'Merhaba') => ({ uid, fromName, subject });

describe('Notifier', () => {
  let s: ReturnType<typeof setup>;
  beforeEach(() => {
    s = setup();
  });

  it('tek ileti için gönderen ve konuyla bildirim atar', async () => {
    s.repo.setUnread(s.account.id, 4);
    await s.notifier.notify(s.repo.getAccount(s.account.id)!, [msg(10)]);

    expect(s.send).toHaveBeenCalledOnce();
    const [token, env, payload] = s.send.mock.calls[0] as unknown as [string, string, any];
    expect(token).toBe(TOKEN);
    expect(env).toBe('development');
    expect(payload.aps.alert).toEqual({ title: 'Ali', body: 'Merhaba' });
    expect(payload.aps.badge).toBe(4);
    expect(payload.aps['thread-id']).toBe('account-7');
    expect(payload.accountId).toBe(7);
    expect(payload.uid).toBe(10);
  });

  it('birden fazla ileti için tek özet bildirim atar', async () => {
    await s.notifier.notify(s.account, [msg(1, 'A', 'x'), msg(2, 'B', 'y'), msg(3, 'C', 'z')]);
    expect(s.send).toHaveBeenCalledOnce();
    const payload = (s.send.mock.calls[0] as unknown as [string, string, any])[2];
    expect(payload.aps.alert.title).toBe('3 yeni ileti');
    expect(payload.aps.alert.body).toBe('C: z');
    expect(payload.uid).toBe(3);
  });

  it('rozet, aynı cihazdaki tüm hesapların toplamıdır', async () => {
    const second = s.repo.upsertAccount({
      apnsToken: TOKEN, environment: 'development', clientAccountId: 8,
      host: 'imap.b.com', port: 993, secure: true, username: 'b', password: 'pw',
    });
    s.repo.setUnread(s.account.id, 2);
    s.repo.setUnread(second.id, 5);
    await s.notifier.notify(s.repo.getAccount(s.account.id)!, [msg(1)]);
    const payload = (s.send.mock.calls[0] as unknown as [string, string, any])[2];
    expect(payload.aps.badge).toBe(7);
  });

  it('geçici hatada yeniden dener, sonunda gönderir', async () => {
    const t = setup([
      { status: 'error', reason: 'ServiceUnavailable', retryable: true },
      { status: 'error', reason: 'ServiceUnavailable', retryable: true },
      { status: 'sent' },
    ]);
    await t.notifier.notify(t.account, [msg(1)]);
    expect(t.send).toHaveBeenCalledTimes(3);
  });

  it('kalıcı hatada yeniden denemez', async () => {
    const t = setup([{ status: 'error', reason: 'PayloadTooLarge', retryable: false }]);
    await t.notifier.notify(t.account, [msg(1)]);
    expect(t.send).toHaveBeenCalledOnce();
  });

  it('geçici hata sürerse deneme sayısı sınırlıdır', async () => {
    const t = setup(
      Array.from({ length: 10 }, () => ({
        status: 'error', reason: 'x', retryable: true,
      }) as ApnsResult),
    );
    await t.notifier.notify(t.account, [msg(1)]);
    expect(t.send).toHaveBeenCalledTimes(3);
  });

  it('geçersiz token cihazı ve hesapları siler', async () => {
    const t = setup([{ status: 'invalid_token', reason: 'Unregistered' }]);
    await t.notifier.notify(t.account, [msg(1)]);
    expect(t.repo.listAccounts()).toHaveLength(0);
    expect(t.removed).toHaveBeenCalledWith([t.account.id]);
  });

  it('ileti yoksa hiçbir şey göndermez', async () => {
    await s.notifier.notify(s.account, []);
    expect(s.send).not.toHaveBeenCalled();
  });
});

describe('describeMessage', () => {
  const make = (over: Partial<FetchMessageObject>): FetchMessageObject =>
    ({
      uid: 5,
      flags: new Set<string>(),
      envelope: { subject: 'Konu', from: [{ name: 'Ali', address: 'ali@x.com' }] },
      ...over,
    }) as FetchMessageObject;

  it('okunmamış iletiyi sadeleştirir', () => {
    expect(describeMessage(make({}))).toEqual({ uid: 5, fromName: 'Ali', subject: 'Konu' });
  });

  it('okunmuş iletiyi atlar', () => {
    expect(describeMessage(make({ flags: new Set(['\\Seen']) }))).toBeNull();
  });

  it('isim yoksa adresi, konu yoksa yer tutucuyu kullanır', () => {
    const m = make({ envelope: { subject: '', from: [{ address: 'ali@x.com' }] } as any });
    expect(describeMessage(m)).toMatchObject({ fromName: 'ali@x.com', subject: '(Konu yok)' });
  });

  it('uzun alanları kısaltır', () => {
    const m = make({ envelope: { subject: 'k'.repeat(500), from: [{ name: 'a' }] } as any });
    expect(describeMessage(m)!.subject.length).toBeLessThanOrEqual(160);
  });
});

describe('backoffDelay', () => {
  it('katlanır ve 60 saniyede sınırlanır', () => {
    const mid = () => 0.5; // sapma çarpanı 1.0
    expect(backoffDelay(0, mid)).toBe(1000);
    expect(backoffDelay(1, mid)).toBe(2000);
    expect(backoffDelay(3, mid)).toBe(8000);
    expect(backoffDelay(20, mid)).toBe(60000);
  });

  it('sapma %20 içinde kalır', () => {
    expect(backoffDelay(2, () => 0)).toBe(3200);
    expect(backoffDelay(2, () => 1)).toBe(4800);
  });
});
