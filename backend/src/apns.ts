import { readFileSync } from 'node:fs';
import http2 from 'node:http2';
import { importPKCS8, SignJWT } from 'jose';
import type { ApnsEnvironment } from './db.js';

export type ApnsResult =
  | { status: 'sent' }
  // Token artık geçersiz (uygulama silinmiş, ortam uyuşmuyor...): kaydı silinmeli.
  | { status: 'invalid_token'; reason: string }
  | { status: 'error'; reason: string; retryable: boolean };

export interface ApnsPayload {
  aps: Record<string, unknown>;
  [key: string]: unknown;
}

export interface ApnsClientOptions {
  keyPem: string;
  keyId: string;
  teamId: string;
  /** Uygulamanın bundle kimliği. */
  topic: string;
  /** Testler için; varsayılan Apple'ın gerçek adresleri. */
  origins?: Record<ApnsEnvironment, string>;
  requestTimeoutMs?: number;
}

const DEFAULT_ORIGINS: Record<ApnsEnvironment, string> = {
  development: 'https://api.sandbox.push.apple.com',
  production: 'https://api.push.apple.com',
};

// Apple: sağlayıcı token'ı 20 dakikadan sık yenilenmemeli, 60 dakikadan eski
// olmamalı.
const JWT_TTL_MS = 50 * 60 * 1000;

// Token'ın kalıcı olarak geçersiz olduğunu gösteren Apple nedenleri.
const INVALID_TOKEN_REASONS = new Set([
  'BadDeviceToken',
  'Unregistered',
  'DeviceTokenNotForTopic',
]);

export class ApnsClient {
  private readonly origins: Record<ApnsEnvironment, string>;
  private readonly sessions = new Map<string, http2.ClientHttp2Session>();
  private readonly timeoutMs: number;
  private jwt: { value: string; issuedAt: number } | null = null;
  private keyPromise: ReturnType<typeof importPKCS8> | null = null;

  constructor(private readonly opts: ApnsClientOptions) {
    this.origins = opts.origins ?? DEFAULT_ORIGINS;
    this.timeoutMs = opts.requestTimeoutMs ?? 10_000;
  }

  static fromKeyFile(
    path: string,
    rest: Omit<ApnsClientOptions, 'keyPem'>,
  ): ApnsClient {
    return new ApnsClient({ ...rest, keyPem: readFileSync(path, 'utf8') });
  }

  async send(
    deviceToken: string,
    environment: ApnsEnvironment,
    payload: ApnsPayload,
    options: { collapseId?: string } = {},
  ): Promise<ApnsResult> {
    let result = await this.attempt(deviceToken, environment, payload, options);
    // Süresi dolmuş/reddedilmiş sağlayıcı token'ı: yenileyip bir kez daha dene.
    if (result.status === 'error' && result.reason === 'ExpiredProviderToken') {
      this.jwt = null;
      result = await this.attempt(deviceToken, environment, payload, options);
    }
    return result;
  }

  close(): void {
    for (const session of this.sessions.values()) session.close();
    this.sessions.clear();
  }

  private async providerToken(): Promise<string> {
    const now = Date.now();
    if (this.jwt && now - this.jwt.issuedAt < JWT_TTL_MS) return this.jwt.value;
    this.keyPromise ??= importPKCS8(this.opts.keyPem, 'ES256');
    const key = await this.keyPromise;
    const value = await new SignJWT({})
      .setProtectedHeader({ alg: 'ES256', kid: this.opts.keyId })
      .setIssuer(this.opts.teamId)
      .setIssuedAt(Math.floor(now / 1000))
      .sign(key);
    this.jwt = { value, issuedAt: now };
    return value;
  }

  private session(origin: string): http2.ClientHttp2Session {
    const existing = this.sessions.get(origin);
    if (existing && !existing.closed && !existing.destroyed) return existing;
    const session = http2.connect(origin);
    const drop = () => {
      if (this.sessions.get(origin) === session) this.sessions.delete(origin);
    };
    session.on('close', drop);
    session.on('goaway', drop);
    // Hata dinleyicisi olmazsa işlenmemiş 'error' süreci düşürür; istek
    // tarafı zaten kendi hatasını alır.
    session.on('error', drop);
    // Boşta kalan bağlantı süreci canlı tutmasın.
    session.unref();
    this.sessions.set(origin, session);
    return session;
  }

  private async attempt(
    deviceToken: string,
    environment: ApnsEnvironment,
    payload: ApnsPayload,
    options: { collapseId?: string },
  ): Promise<ApnsResult> {
    let bearer: string;
    try {
      bearer = await this.providerToken();
    } catch (e) {
      return { status: 'error', reason: `jwt: ${(e as Error).message}`, retryable: false };
    }

    const origin = this.origins[environment];
    return new Promise<ApnsResult>((resolve) => {
      let settled = false;
      const finish = (r: ApnsResult) => {
        if (settled) return;
        settled = true;
        resolve(r);
      };
      const fail = (reason: string) =>
        finish({ status: 'error', reason, retryable: true });

      let req: http2.ClientHttp2Stream;
      try {
        const headers: http2.OutgoingHttpHeaders = {
          ':method': 'POST',
          ':path': `/3/device/${deviceToken}`,
          authorization: `bearer ${bearer}`,
          'apns-topic': this.opts.topic,
          'apns-push-type': 'alert',
          'apns-priority': '10',
        };
        if (options.collapseId) headers['apns-collapse-id'] = options.collapseId;
        req = this.session(origin).request(headers);
      } catch (e) {
        return fail(`connect: ${(e as Error).message}`);
      }

      req.setTimeout(this.timeoutMs, () => {
        req.close(http2.constants.NGHTTP2_CANCEL);
        fail('timeout');
      });
      req.on('error', (e) => fail(`request: ${e.message}`));

      let status = 0;
      let raw = '';
      req.on('response', (h) => {
        status = Number(h[':status'] ?? 0);
      });
      req.setEncoding('utf8');
      req.on('data', (chunk: string) => {
        raw += chunk;
      });
      req.on('end', () => {
        if (status === 200) return finish({ status: 'sent' });
        let reason = `http ${status}`;
        try {
          const parsed = JSON.parse(raw) as { reason?: string };
          if (parsed.reason) reason = parsed.reason;
        } catch {
          // gövde JSON değil; durum kodu yeterli
        }
        if (status === 410 || INVALID_TOKEN_REASONS.has(reason)) {
          return finish({ status: 'invalid_token', reason });
        }
        // 429 ve 5xx geçici; diğer 4xx istekle ilgili kalıcı hatadır.
        const retryable = status === 429 || status >= 500;
        finish({ status: 'error', reason, retryable });
      });

      req.end(JSON.stringify(payload));
    });
  }
}

/** Yeni posta bildirimi için standart payload. */
export function buildMailPayload(input: {
  title: string;
  body: string;
  badge?: number;
  threadId?: string;
  data?: Record<string, unknown>;
}): ApnsPayload {
  const aps: Record<string, unknown> = {
    alert: { title: input.title, body: input.body },
    sound: 'default',
    'mutable-content': 1,
  };
  if (input.badge !== undefined) aps.badge = input.badge;
  if (input.threadId) aps['thread-id'] = input.threadId;
  return { aps, ...input.data };
}
