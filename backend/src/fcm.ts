import { importPKCS8, SignJWT } from 'jose';

export type FcmResult =
  | { status: 'sent' }
  // Token artık geçersiz (uygulama silinmiş, token yenilenmiş...): kayıt silinmeli.
  | { status: 'invalid_token'; reason: string }
  | { status: 'error'; reason: string; retryable: boolean };

export interface FcmServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri?: string;
}

export interface FcmClientOptions {
  account: FcmServiceAccount;
  /** Testler için; varsayılan global `fetch`. */
  fetch?: typeof fetch;
  requestTimeoutMs?: number;
  now?: () => number;
}

const SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';
const DEFAULT_TOKEN_URI = 'https://oauth2.googleapis.com/token';
// Erişim token'ı 1 saat geçerlidir; süresi dolmadan önce yenilenir.
const REFRESH_MARGIN_MS = 5 * 60 * 1000;

/**
 * Service account JSON'unu (ham ya da base64) ayrıştırır. Eksik/bozuk alan
 * başlangıçta anlaşılır bir hatayla yakalanır; ilk push'a kadar saklanmaz.
 */
export function parseServiceAccount(raw: string): FcmServiceAccount {
  const text = raw.trim().startsWith('{')
    ? raw
    : Buffer.from(raw.trim(), 'base64').toString('utf8');
  let parsed: Partial<FcmServiceAccount>;
  try {
    parsed = JSON.parse(text) as Partial<FcmServiceAccount>;
  } catch {
    throw new Error('FCM_SERVICE_ACCOUNT geçerli JSON (ya da base64 JSON) değil');
  }
  const { project_id, client_email, private_key } = parsed;
  if (!project_id || !client_email || !private_key) {
    throw new Error(
      'FCM_SERVICE_ACCOUNT project_id, client_email ve private_key içermeli',
    );
  }
  return { ...parsed, project_id, client_email, private_key };
}

/**
 * Firebase Cloud Messaging HTTP v1 istemcisi. `firebase-admin` (onlarca MB,
 * gRPC) yerine yalnızca gereken iki çağrı yapılır: OAuth erişim token'ı almak
 * ve `messages:send`.
 */
export class FcmClient {
  private readonly fetchFn: typeof fetch;
  private readonly timeoutMs: number;
  private readonly now: () => number;
  private access: { value: string; expiresAt: number } | null = null;
  private inflight: Promise<string> | null = null;
  private keyPromise: ReturnType<typeof importPKCS8> | null = null;

  constructor(private readonly opts: FcmClientOptions) {
    this.fetchFn = opts.fetch ?? fetch;
    this.timeoutMs = opts.requestTimeoutMs ?? 10_000;
    this.now = opts.now ?? Date.now;
  }

  get projectId(): string {
    return this.opts.account.project_id;
  }

  /** Anahtarın gerçekten token alabildiğini doğrular (bkz. `ApnsClient.verifyKey`). */
  async verifyKey(): Promise<void> {
    this.access = null;
    await this.accessToken();
  }

  /**
   * Yalnızca-veri (data-only) yüksek öncelikli mesaj gönderir. Bildirimi
   * uygulama kendisi üretir (bkz. lib/app/fcm_background.dart); böylece
   * eylem düğmeleri, gruplama ve yerel iletiyle eşleşme tek yerde kalır ve
   * ileti içeriği Google sunucularından geçmez.
   */
  async send(
    token: string,
    data: Record<string, string>,
    options: { collapseKey?: string; ttlSeconds?: number } = {},
  ): Promise<FcmResult> {
    let result = await this.attempt(token, data, options);
    if (result.status === 'error' && result.reason === 'UNAUTHENTICATED') {
      this.access = null;
      result = await this.attempt(token, data, options);
    }
    return result;
  }

  private async accessToken(): Promise<string> {
    const now = this.now();
    if (this.access && now < this.access.expiresAt - REFRESH_MARGIN_MS) {
      return this.access.value;
    }
    // Eşzamanlı çağrılar tek token isteğinde birleşir.
    this.inflight ??= this.fetchAccessToken().finally(() => {
      this.inflight = null;
    });
    return this.inflight;
  }

  private async fetchAccessToken(): Promise<string> {
    const { account } = this.opts;
    const tokenUri = account.token_uri ?? DEFAULT_TOKEN_URI;
    this.keyPromise ??= importPKCS8(account.private_key, 'RS256');
    const key = await this.keyPromise;
    const issuedAt = Math.floor(this.now() / 1000);
    const assertion = await new SignJWT({ scope: SCOPE })
      .setProtectedHeader({ alg: 'RS256', typ: 'JWT' })
      .setIssuer(account.client_email)
      .setSubject(account.client_email)
      .setAudience(tokenUri)
      .setIssuedAt(issuedAt)
      .setExpirationTime(issuedAt + 3600)
      .sign(key);

    const res = await this.fetchFn(tokenUri, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        assertion,
      }),
      signal: AbortSignal.timeout(this.timeoutMs),
    });
    if (!res.ok) throw new Error(`FCM OAuth http ${res.status}`);
    const body = (await res.json()) as { access_token?: string; expires_in?: number };
    if (!body.access_token) throw new Error('FCM OAuth yanıtında access_token yok');
    this.access = {
      value: body.access_token,
      expiresAt: this.now() + (body.expires_in ?? 3600) * 1000,
    };
    return body.access_token;
  }

  private async attempt(
    token: string,
    data: Record<string, string>,
    options: { collapseKey?: string; ttlSeconds?: number },
  ): Promise<FcmResult> {
    let bearer: string;
    try {
      bearer = await this.accessToken();
    } catch (e) {
      return { status: 'error', reason: `oauth: ${(e as Error).message}`, retryable: true };
    }

    const message = {
      message: {
        token,
        data,
        android: {
          // Yüksek öncelik Doze'da uygulamayı uyandırır; normal öncelik
          // bakım penceresine kadar bekletilir.
          priority: 'HIGH',
          ttl: `${options.ttlSeconds ?? 3600}s`,
          ...(options.collapseKey ? { collapse_key: options.collapseKey } : {}),
        },
      },
    };

    let res: Response;
    try {
      res = await this.fetchFn(
        `https://fcm.googleapis.com/v1/projects/${this.projectId}/messages:send`,
        {
          method: 'POST',
          headers: {
            authorization: `Bearer ${bearer}`,
            'content-type': 'application/json',
          },
          body: JSON.stringify(message),
          signal: AbortSignal.timeout(this.timeoutMs),
        },
      );
    } catch (e) {
      return { status: 'error', reason: `request: ${(e as Error).message}`, retryable: true };
    }
    if (res.ok) return { status: 'sent' };

    let status = '';
    let errorCode = '';
    try {
      const parsed = (await res.json()) as {
        error?: { status?: string; details?: { errorCode?: string }[] };
      };
      status = parsed.error?.status ?? '';
      errorCode = parsed.error?.details?.find((d) => d.errorCode)?.errorCode ?? '';
    } catch {
      // gövde JSON değil; durum kodu yeterli
    }
    const reason = errorCode || status || `http ${res.status}`;
    // UNREGISTERED: token kalıcı olarak geçersiz. INVALID_ARGUMENT bilerek
    // BURADA DEĞİL: yük hatası da aynı kodu verir ve bir yazılım hatası tüm
    // cihaz kayıtlarını sildirmemeli; kalıcı hata olarak günlüğe düşer.
    if (reason === 'UNREGISTERED' || res.status === 404 || reason === 'SENDER_ID_MISMATCH') {
      return { status: 'invalid_token', reason };
    }
    if (res.status === 401 || reason === 'UNAUTHENTICATED') {
      return { status: 'error', reason: 'UNAUTHENTICATED', retryable: false };
    }
    // 429 (kota) ve 5xx geçici; diğer 4xx istekle ilgili kalıcı hatadır.
    const retryable = res.status === 429 || res.status >= 500;
    return { status: 'error', reason, retryable };
  }
}
