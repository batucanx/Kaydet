import { generateKeyPairSync } from 'node:crypto';
import { describe, expect, it, vi } from 'vitest';
import { FcmClient, parseServiceAccount } from '../src/fcm.js';

const { privateKey } = generateKeyPairSync('rsa', {
  modulusLength: 2048,
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  publicKeyEncoding: { type: 'spki', format: 'pem' },
});

const account = {
  project_id: 'kaydet-test',
  client_email: 'svc@kaydet-test.iam.gserviceaccount.com',
  private_key: privateKey,
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

/** `oauth2` adresine gelen istek erişim token'ı, diğerleri `messages:send` sayılır. */
function setup(sendResponses: Response[]) {
  const calls: { url: string; init?: RequestInit }[] = [];
  const queue = [...sendResponses];
  const fetchFn = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
    const u = String(url);
    calls.push({ url: u, init });
    if (u.includes('oauth2')) return json({ access_token: 'at-1', expires_in: 3600 });
    return queue.shift() ?? json({ name: 'ok' });
  }) as unknown as typeof fetch;
  const client = new FcmClient({ account, fetch: fetchFn });
  return { client, calls, fetchFn };
}

describe('parseServiceAccount', () => {
  it('ham JSON ve base64 JSON kabul eder', () => {
    const raw = JSON.stringify(account);
    expect(parseServiceAccount(raw).project_id).toBe('kaydet-test');
    expect(parseServiceAccount(Buffer.from(raw).toString('base64')).client_email).toBe(
      account.client_email,
    );
  });

  it('eksik alanı ve bozuk JSON reddeder', () => {
    expect(() => parseServiceAccount('{"project_id":"x"}')).toThrow(/private_key/);
    expect(() => parseServiceAccount('%%%')).toThrow(/JSON/);
  });
});

describe('FcmClient', () => {
  it('yalnızca-veri, yüksek öncelikli mesaj gönderir ve erişim token ını yeniden kullanır', async () => {
    const s = setup([]);
    const data = { type: 'new_mail', accountId: '3' };
    expect(await s.client.send('tok', data, { collapseKey: 'account-3' })).toEqual({ status: 'sent' });
    await s.client.send('tok', data);

    const oauth = s.calls.filter((c) => c.url.includes('oauth2'));
    expect(oauth).toHaveLength(1); // ikinci gönderimde önbellekten

    const send = s.calls.find((c) => c.url.includes('messages:send'))!;
    expect(send.url).toContain('/projects/kaydet-test/');
    expect((send.init!.headers as Record<string, string>).authorization).toBe('Bearer at-1');
    const body = JSON.parse(String(send.init!.body));
    expect(body.message.token).toBe('tok');
    expect(body.message.data).toEqual(data);
    expect(body.message.notification).toBeUndefined();
    expect(body.message.android.priority).toBe('HIGH');
    expect(body.message.android.collapse_key).toBe('account-3');
  });

  it('UNREGISTERED token ı geçersiz sayar', async () => {
    const s = setup([
      json({ error: { status: 'NOT_FOUND', details: [{ errorCode: 'UNREGISTERED' }] } }, 404),
    ]);
    expect(await s.client.send('tok', {})).toEqual({ status: 'invalid_token', reason: 'UNREGISTERED' });
  });

  it('INVALID_ARGUMENT cihaz silmeye yol açmaz (kalıcı hata)', async () => {
    const s = setup([json({ error: { status: 'INVALID_ARGUMENT' } }, 400)]);
    expect(await s.client.send('tok', {})).toEqual({
      status: 'error',
      reason: 'INVALID_ARGUMENT',
      retryable: false,
    });
  });

  it('429 ve 5xx geçici hatadır', async () => {
    const s = setup([json({ error: { status: 'QUOTA_EXCEEDED' } }, 429), json({}, 503)]);
    expect(await s.client.send('tok', {})).toMatchObject({ status: 'error', retryable: true });
    expect(await s.client.send('tok', {})).toMatchObject({ status: 'error', retryable: true });
  });

  it('UNAUTHENTICATED olunca erişim token ı yenilenip bir kez daha denenir', async () => {
    const s = setup([json({ error: { status: 'UNAUTHENTICATED' } }, 401)]);
    expect(await s.client.send('tok', {})).toEqual({ status: 'sent' });
    expect(s.calls.filter((c) => c.url.includes('oauth2'))).toHaveLength(2);
  });

  it('OAuth başarısızsa geçici hata döner', async () => {
    const fetchFn = vi.fn(async () => json({}, 500)) as unknown as typeof fetch;
    const client = new FcmClient({ account, fetch: fetchFn });
    expect(await client.send('tok', {})).toMatchObject({ status: 'error', retryable: true });
  });
});
