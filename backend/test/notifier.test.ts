import type { FetchMessageObject } from 'imapflow';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { ApnsResult } from '../src/apns.js';
import { SecretBox } from '../src/crypto.js';
import { openDatabase } from '../src/db.js';
import { Notifier } from '../src/notifier.js';
import { Repository } from '../src/repository.js';
import { backoffDelay, describeMessage, staggerOffsets } from '../src/watcher.js';

const TOKEN = 'ab'.repeat(32);

function setup(results: ApnsResult[] = []) {
  const db = openDatabase(':memory:');
  const repo = new Repository(db, new SecretBox('c'.repeat(64)));
  const account = repo.upsertAccount({
    installId: 'a'.repeat(32),
    pushToken: TOKEN,
    platform: 'ios',
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
    expect(payload.aps['content-available']).toBe(1);
    expect(payload.aps['thread-id']).toBe('account-7');
    expect(payload.accountId).toBe(7);
    expect(payload.uid).toBe(10);
  });

  it('bildirim hedefini (tür, klasör, uidValidity, Message-ID) yükte taşır', async () => {
    await s.notifier.notify(
      s.account,
      [{ ...msg(10), messageId: '<abc@mail.example>' }],
      4242,
    );
    const payload = (s.send.mock.calls[0] as unknown as [string, string, any])[2];
    expect(payload.type).toBe('new_mail');
    expect(payload.folder).toBe('INBOX');
    expect(payload.uidValidity).toBe(4242);
    expect(payload.messageId).toBe('<abc@mail.example>');
  });

  it('uidValidity ve Message-ID yoksa bu alanları hiç koymaz', async () => {
    await s.notifier.notify(s.account, [msg(10)]);
    const payload = (s.send.mock.calls[0] as unknown as [string, string, any])[2];
    expect(payload).not.toHaveProperty('uidValidity');
    expect(payload).not.toHaveProperty('messageId');
  });

  it('birden fazla ileti için tek özet bildirim atar', async () => {
    await s.notifier.notify(s.account, [msg(1, 'A', 'x'), msg(2, 'B', 'y'), msg(3, 'C', 'z')]);
    expect(s.send).toHaveBeenCalledOnce();
    const payload = (s.send.mock.calls[0] as unknown as [string, string, any])[2];
    expect(payload.aps.alert.title).toBe('3 yeni ileti');
    expect(payload.aps.alert.body).toBe('C: z');
    expect(payload.uid).toBe(3);
  });

  it('yüke uzantının okuyacağı kompakt ileti listesini koyar (en çok 8)', async () => {
    const many = Array.from({ length: 12 }, (_, i) => msg(i + 1, 'A', 'x'));
    many[11] = { ...many[11]!, date: '2026-10-07T01:00:00.000Z' } as any;
    await s.notifier.notify(s.account, many);
    const payload = (s.send.mock.calls[0] as unknown as [string, string, any])[2];
    expect(payload.items).toHaveLength(8);
    expect(payload.items[0]).toEqual({ u: 5, f: 'A', s: 'x' });
    expect(payload.items[7]).toEqual({ u: 12, f: 'A', s: 'x', d: '2026-10-07T01:00:00.000Z' });
    expect(JSON.stringify(payload).length).toBeLessThan(4096);
  });

  it('rozet, aynı cihazdaki tüm hesapların toplamıdır', async () => {
    const second = s.repo.upsertAccount({
    installId: 'a'.repeat(32),
      pushToken: TOKEN, platform: 'ios', environment: 'development', clientAccountId: 8,
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

  it('zarftaki Message-ID değerini taşır', () => {
    const result = describeMessage(
      make({ envelope: { subject: 'Konu', messageId: '<a@b>', from: [{ address: 'x@y.com' }] } as any }),
    );
    expect(result?.messageId).toBe('<a@b>');
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

describe('Notifier (Android / FCM)', () => {
  const FCM_TOKEN = 'f'.repeat(30) + ':' + 'A'.repeat(120);

  function androidSetup(results: any[] = []) {
    const db = openDatabase(':memory:');
    const repo = new Repository(db, new SecretBox('c'.repeat(64)));
    const account = repo.upsertAccount({
      installId: 'a'.repeat(32),
      pushToken: FCM_TOKEN,
      platform: 'android',
      environment: 'production',
      clientAccountId: 4,
      host: 'imap.example.com',
      port: 993,
      secure: true,
      username: 'me@example.com',
      password: 'pw',
    });
    const fcmSend = vi.fn(async () => results.shift() ?? { status: 'sent' });
    const apnsSend = vi.fn(async () => ({ status: 'sent' }) as ApnsResult);
    const removed = vi.fn();
    const notifier = new Notifier(repo, { send: apnsSend }, {
      fcm: { send: fcmSend },
      onDevicesRemoved: removed,
      sleep: async () => {},
    });
    return { repo, account, fcmSend, apnsSend, removed, notifier };
  }

  it('APNs yerine FCM kullanır ve ileti içeriğini göndermez', async () => {
    const s = androidSetup();
    await s.notifier.notify(s.account, [msg(10, 'Gizli Gönderen', 'Gizli Konu'), msg(11)], 99);
    expect(s.apnsSend).not.toHaveBeenCalled();
    const [token, data, options] = s.fcmSend.mock.calls[0] as unknown as [string, Record<string, string>, any];
    expect(token).toBe(FCM_TOKEN);
    expect(data).toEqual({
      type: 'new_mail',
      accountId: '4',
      folder: 'INBOX',
      uid: '11',
      count: '2',
      uidValidity: '99',
    });
    expect(JSON.stringify(data)).not.toContain('Gizli');
    expect(options.collapseKey).toBe('account-4');
  });

  it('geçici hatada yeniden dener', async () => {
    const s = androidSetup([{ status: 'error', reason: 'x', retryable: true }]);
    await s.notifier.notify(s.account, [msg(1)]);
    expect(s.fcmSend).toHaveBeenCalledTimes(2);
  });

  it('geçersiz token cihazı siler', async () => {
    const s = androidSetup([{ status: 'invalid_token', reason: 'UNREGISTERED' }]);
    await s.notifier.notify(s.account, [msg(1)]);
    expect(s.removed).toHaveBeenCalledWith([s.account.id]);
    expect(s.repo.getDevice(s.account.device_id)).toBeUndefined();
  });

  it('FCM yapılandırılmamışsa sessizce atlar', async () => {
    const db = openDatabase(':memory:');
    const repo = new Repository(db, new SecretBox('c'.repeat(64)));
    const account = repo.upsertAccount({
      installId: 'a'.repeat(32), pushToken: FCM_TOKEN, platform: 'android', environment: 'production',
      clientAccountId: 1, host: 'h', port: 993, secure: true, username: 'u', password: 'p',
    });
    const apnsSend = vi.fn();
    await new Notifier(repo, { send: apnsSend }).notify(account, [msg(1)]);
    expect(apnsSend).not.toHaveBeenCalled();
  });
});

describe('staggerOffsets', () => {
  const opts = { globalMs: 100, perHostMs: 1000 };

  it('farklı sunucular yalnızca genel aralıkla ayrılır', () => {
    expect(staggerOffsets(['a.com', 'b.com', 'c.com'], opts)).toEqual([0, 100, 200]);
  });

  it('aynı sunucuya bağlantılar perHostMs aralıkla gider (büyük/küçük harf fark etmez)', () => {
    expect(staggerOffsets(['x.com', 'X.com', 'x.com'], opts)).toEqual([0, 1000, 2000]);
  });

  it('aynı sunucunun beklemesi diğer sunucuları geciktirmez', () => {
    // 2. hesap x.com için 1000'e gider; y.com onu beklemeden hemen sonraki boş aralığa girer.
    expect(staggerOffsets(['x.com', 'x.com', 'y.com'], opts)).toEqual([0, 1000, 100]);
  });

  it('hiçbir iki başlatma aynı anda olmaz ve aynı sunucu aralığı korunur', () => {
    const hosts = Array.from({ length: 200 }, (_, i) => `h${i % 5}.com`);
    const at = staggerOffsets(hosts, opts);
    expect(new Set(at).size).toBe(at.length);
    for (let h = 0; h < 5; h++) {
      const mine = at.filter((_, i) => i % 5 === h).sort((a, b) => a - b);
      for (let i = 1; i < mine.length; i++) expect(mine[i]! - mine[i - 1]!).toBeGreaterThanOrEqual(1000);
    }
  });

  it('boş listede boş döner', () => {
    expect(staggerOffsets([], opts)).toEqual([]);
  });
});
