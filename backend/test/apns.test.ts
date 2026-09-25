import { generateKeyPairSync } from 'node:crypto';
import http2 from 'node:http2';
import type { AddressInfo } from 'node:net';
import { decodeJwt, decodeProtectedHeader } from 'jose';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { ApnsClient, buildMailPayload } from '../src/apns.js';

const TOKEN = 'ab'.repeat(32);

interface Seen {
  path: string;
  headers: http2.IncomingHttpHeaders;
  body: string;
}

describe('ApnsClient', () => {
  let server: http2.Http2Server;
  let origin: string;
  let seen: Seen[];
  // Her istek için sıradaki yanıt; boşsa 200.
  let responses: { status: number; body?: object }[];
  let client: ApnsClient;

  beforeEach(async () => {
    seen = [];
    responses = [];
    server = http2.createServer((req, res) => {
      let body = '';
      req.on('data', (c) => (body += c));
      req.on('end', () => {
        seen.push({ path: req.url ?? '', headers: req.headers, body });
        const next = responses.shift() ?? { status: 200 };
        res.writeHead(next.status);
        res.end(next.body ? JSON.stringify(next.body) : undefined);
      });
    });
    await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
    origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;

    const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
    client = new ApnsClient({
      keyPem: privateKey.export({ type: 'pkcs8', format: 'pem' }).toString(),
      keyId: 'KEY1234567',
      teamId: 'TEAM123456',
      topic: 'tr.com.pazarlik.kaydet',
      origins: { development: origin, production: origin },
      requestTimeoutMs: 1000,
    });
  });

  afterEach(async () => {
    client.close();
    await new Promise((r) => server.close(r));
  });

  const payload = () => buildMailPayload({ title: 'Ali', body: 'Merhaba', badge: 3 });

  it('doğru başlıklar, JWT ve gövdeyle gönderir', async () => {
    const result = await client.send(TOKEN, 'development', payload());
    expect(result).toEqual({ status: 'sent' });

    const [req] = seen;
    expect(req!.path).toBe(`/3/device/${TOKEN}`);
    expect(req!.headers['apns-topic']).toBe('tr.com.pazarlik.kaydet');
    expect(req!.headers['apns-push-type']).toBe('alert');

    const jwt = (req!.headers.authorization as string).replace(/^bearer /, '');
    expect(decodeProtectedHeader(jwt)).toMatchObject({ alg: 'ES256', kid: 'KEY1234567' });
    expect(decodeJwt(jwt).iss).toBe('TEAM123456');

    const sent = JSON.parse(req!.body);
    expect(sent.aps.alert).toEqual({ title: 'Ali', body: 'Merhaba' });
    expect(sent.aps.badge).toBe(3);
  });

  it('JWT önbelleğe alınır, her istekte yeniden imzalanmaz', async () => {
    await client.send(TOKEN, 'development', payload());
    await client.send(TOKEN, 'development', payload());
    expect(seen[1]!.headers.authorization).toBe(seen[0]!.headers.authorization);
  });

  it('410 Unregistered token’ı geçersiz sayar', async () => {
    responses = [{ status: 410, body: { reason: 'Unregistered' } }];
    expect(await client.send(TOKEN, 'production', payload())).toEqual({
      status: 'invalid_token',
      reason: 'Unregistered',
    });
  });

  it('400 BadDeviceToken token’ı geçersiz sayar', async () => {
    responses = [{ status: 400, body: { reason: 'BadDeviceToken' } }];
    const r = await client.send(TOKEN, 'production', payload());
    expect(r.status).toBe('invalid_token');
  });

  it('ExpiredProviderToken alınca yeni JWT ile bir kez yeniden dener', async () => {
    responses = [{ status: 403, body: { reason: 'ExpiredProviderToken' } }, { status: 200 }];
    const r = await client.send(TOKEN, 'development', payload());
    expect(r).toEqual({ status: 'sent' });
    expect(seen).toHaveLength(2);
  });

  it('429 ve 5xx geçici hata, diğer 4xx kalıcı hata', async () => {
    responses = [
      { status: 429, body: { reason: 'TooManyRequests' } },
      { status: 503, body: { reason: 'ServiceUnavailable' } },
      { status: 400, body: { reason: 'PayloadTooLarge' } },
    ];
    const results = [
      await client.send(TOKEN, 'development', payload()),
      await client.send(TOKEN, 'development', payload()),
      await client.send(TOKEN, 'development', payload()),
    ];
    expect(results).toEqual([
      { status: 'error', reason: 'TooManyRequests', retryable: true },
      { status: 'error', reason: 'ServiceUnavailable', retryable: true },
      { status: 'error', reason: 'PayloadTooLarge', retryable: false },
    ]);
  });

  it('sunucuya ulaşılamazsa geçici hata döner', async () => {
    const dead = new ApnsClient({
      keyPem: generateKeyPairSync('ec', { namedCurve: 'P-256' })
        .privateKey.export({ type: 'pkcs8', format: 'pem' })
        .toString(),
      keyId: 'K',
      teamId: 'T',
      topic: 'x',
      origins: { development: 'http://127.0.0.1:1', production: 'http://127.0.0.1:1' },
      requestTimeoutMs: 500,
    });
    const r = await dead.send(TOKEN, 'development', payload());
    dead.close();
    expect(r).toMatchObject({ status: 'error', retryable: true });
  });
});

describe('buildMailPayload', () => {
  it('isteğe bağlı alanları yalnızca verilince ekler', () => {
    const p = buildMailPayload({
      title: 'a',
      body: 'b',
      threadId: 'acct-1',
      data: { accountId: 1, uid: 9 },
    });
    expect(p.aps['thread-id']).toBe('acct-1');
    expect(p.aps.badge).toBeUndefined();
    expect(p.accountId).toBe(1);
    expect(p.uid).toBe(9);
  });
});
