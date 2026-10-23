import Fastify, { type FastifyInstance } from 'fastify';
import { timingSafeEqual } from 'node:crypto';
import { z } from 'zod';
import type { AccountRow } from './db.js';
import {
  INSTALL_ID_PATTERN,
  INSTALL_SECRET_PATTERN,
  type InstallRegistry,
} from './installs.js';
import { InstallLimitError, type Repository } from './repository.js';
import type { TranslationService } from './translation.js';
import type { WatchStatus } from './watcher.js';

/** İzleyici (IDLE) katmanının hesap değişikliklerinden haberdar olması için. */
export interface AccountHooks {
  onAccountUpserted(account: AccountRow): void;
  onAccountsRemoved(accountIds: number[]): void;
  /**
   * Hesabın şu anki izleme durumu; izleyicisi yoksa `undefined`. Yoksa (testler,
   * izleyicisiz kurulum) `GET /v1/accounts` durumu `stopped` bildirir.
   */
  statusOf?(accountId: number): WatchStatus | undefined;
}

const noopHooks: AccountHooks = {
  onAccountUpserted() {},
  onAccountsRemoved() {},
};

// Cihaz push token'ı. iOS: APNs (32 bayt = 64 hex; Apple ileride uzatabilir).
// Android: FCM kayıt token'ı (`:` ile bölünen, URL-güvenli karakterli dize).
const apnsTokenPattern = /^[0-9a-fA-F]{64,200}$/;
const fcmTokenPattern = /^[A-Za-z0-9_:\-]{100,4096}$/;

const platformSchema = z.enum(['ios', 'android']);

/**
 * Eski iOS istemcileri `apnsToken` alanını ve platform bilgisini göndermez;
 * yeni istemciler `pushToken` + `platform` gönderir. İkisi de kabul edilir
 * (sunucu, istemcilerden ÖNCE dağıtılabilsin diye). Token biçimi platforma
 * göre doğrulanır; iOS token'ı küçük harfe çevrilir.
 */
const tokenFields = {
  pushToken: z.string().optional(),
  apnsToken: z.string().optional(),
  platform: platformSchema.optional(),
};

type TokenFields = {
  pushToken?: string | undefined;
  apnsToken?: string | undefined;
  platform?: 'ios' | 'android' | undefined;
};

function normalizeToken(
  input: TokenFields,
  ctx: z.RefinementCtx,
): { pushToken: string; platform: 'ios' | 'android' } {
  const platform = input.platform ?? 'ios';
  const raw = input.pushToken ?? input.apnsToken;
  const pattern = platform === 'ios' ? apnsTokenPattern : fcmTokenPattern;
  if (!raw || !pattern.test(raw)) {
    ctx.addIssue({
      code: 'custom',
      path: ['pushToken'],
      message: platform === 'ios' ? 'Geçersiz APNs token' : 'Geçersiz FCM token',
    });
    return z.NEVER;
  }
  return { pushToken: platform === 'ios' ? raw.toLowerCase() : raw, platform };
}

const upsertSchema = z
  .object({
    ...tokenFields,
    environment: z.enum(['development', 'production']).default('production'),
    clientAccountId: z.number().int().nonnegative(),
    imap: z.object({
      host: z.string().min(1).max(255),
      port: z.number().int().min(1).max(65535),
      secure: z.boolean(),
    }),
    username: z.string().min(1).max(320),
    password: z.string().min(1).max(1024),
  })
  .transform((b, ctx) => ({ ...b, ...normalizeToken(b, ctx) }));

const deleteAccountSchema = z
  .object({ ...tokenFields, clientAccountId: z.number().int().nonnegative() })
  .transform((b, ctx) => ({ ...b, ...normalizeToken(b, ctx) }));

const deleteDeviceSchema = z
  .object(tokenFields)
  .transform((b, ctx) => ({ ...b, ...normalizeToken(b, ctx) }));

const languageSchema = z.string().regex(/^[a-zA-Z]{2,3}(-[a-zA-Z0-9]{2,8})*$/);

const translateSchema = z.object({
  // Kullanıcı bazlı kota için kararlı, istemciye özel kimlik (bkz. app tarafı).
  // İstemcinin gönderdiği değer yok sayılır: kota, sunucunun doğruladığı
  // kurulum kimliğine bağlanır (bkz. installs.ts). Eski istemciler için kabul edilir.
  userId: z.string().min(8).max(128).optional(),
  messageId: z.string().min(1).max(200),
  // `auto`: kaynak dil sağlayıcıya bırakılır.
  sourceLanguage: z.union([z.literal('auto'), languageSchema]),
  targetLanguage: languageSchema,
  subject: z.string().max(100_000),
  segments: z.array(z.string().max(100_000)).max(20_000),
});

const detectSchema = z.object({
  userId: z.string().min(8).max(128).optional(),
  sample: z.string().max(20_000),
});

function safeEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  return ab.length === bb.length && timingSafeEqual(ab, bb);
}

declare module 'fastify' {
  interface FastifyRequest {
    /** Doğrulanmış kurulum kimliği; `/health` dışındaki her istekte dolu. */
    installId: string;
  }
}

export function buildApp(opts: {
  repo: Repository;
  installs: InstallRegistry;
  apiKey: string;
  hooks?: AccountHooks;
  /** Verilmezse `/v1/translate` TRANSLATION_UNAVAILABLE döner. */
  translation?: TranslationService;
  /** Android (FCM) gönderimi yapılandırıldı mı? Yoksa Android kayıtları 503 alır. */
  androidPush?: boolean;
  /** Ters vekil arkasındaysa `true` (X-Forwarded-For'a güvenir). */
  trustProxy?: boolean;
}): FastifyInstance {
  const { repo, apiKey, installs } = opts;
  const hooks = opts.hooks ?? noopHooks;
  // İstek gövdeleri şifre içerir; istek loglaması bilerek kapalı.
  // Railway vb. ters vekil arkasında istemci IP'si için (yeni kurulum limiti).
  const app = Fastify({ logger: false, trustProxy: opts.trustProxy ?? false });
  app.decorateRequest('installId', '');

  app.get('/health', async () => ({ ok: true }));

  app.addHook('preHandler', async (request, reply) => {
    if (request.url === '/health') return;
    const header = request.headers.authorization ?? '';
    const token = header.startsWith('Bearer ') ? header.slice(7) : '';
    if (!safeEqual(token, apiKey)) {
      return reply.code(401).send({ error: 'unauthorized' });
    }

    const installId = String(request.headers['x-install-id'] ?? '');
    const installSecret = String(request.headers['x-install-secret'] ?? '');
    if (
      !INSTALL_ID_PATTERN.test(installId) ||
      !INSTALL_SECRET_PATTERN.test(installSecret)
    ) {
      return reply.code(401).send({ error: 'install_required' });
    }
    const verdict = installs.check(installId, installSecret, request.ip);
    if (verdict === 'bad_secret') {
      return reply.code(401).send({ error: 'install_invalid' });
    }
    if (verdict === 'rate_limited') {
      return reply.code(429).send({ error: 'install_rate_limited' });
    }
    request.installId = installId;
  });

  const tokenQuerySchema = z
    .object(tokenFields)
    .transform((b, ctx) => ({ ...b, ...normalizeToken(b, ctx) }));

  app.get('/v1/accounts', async (request, reply) => {
    const parsed = tokenQuerySchema.safeParse(request.query);
    if (!parsed.success) {
      return reply
        .code(400)
        .send({ error: 'invalid_request', issues: parsed.error.issues });
    }
    const rows = repo.listDeviceAccounts(parsed.data.pushToken);
    return reply.send({
      // Eski istemciler yalnızca bu alanı okur.
      clientAccountIds: rows.map((r) => r.client_account_id),
      // Her hesabın sunucudaki GERÇEK izleme durumu: "kayıtlı" olmak "izleniyor"
      // demek değildir (kimlik reddedilmiş ya da sunucuya ulaşılamıyor olabilir).
      // İstemci buna bakıp şifreyi yeniden gönderir ya da yedek izlemeye geçer.
      accounts: rows.map((r) => ({
        clientAccountId: r.client_account_id,
        status: hooks.statusOf?.(r.id) ?? 'stopped',
      })),
    });
  });

  app.put('/v1/accounts', async (request, reply) => {
    const parsed = upsertSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply
        .code(400)
        .send({ error: 'invalid_request', issues: parsed.error.issues });
    }
    const b = parsed.data;
    if (b.platform === 'android' && !opts.androidPush) {
      // Sunucuda FCM yapılandırılmamış: kayıt sessizce kabul edilirse
      // kullanıcı hiç push alamaz ve nedenini bilemez. İstemci bunu geçici
      // hata sayıp ön plan servisine düşer.
      return reply.code(503).send({ error: 'android_push_unavailable' });
    }
    let account: AccountRow;
    let superseded: number[];
    try {
      ({ account, supersededAccountIds: superseded } = repo.upsertAccountDetailed({
        installId: request.installId,
        pushToken: b.pushToken,
        platform: b.platform,
        environment: b.platform === 'android' ? 'production' : b.environment,
        clientAccountId: b.clientAccountId,
        host: b.imap.host,
        port: b.imap.port,
        secure: b.imap.secure,
        username: b.username,
        password: b.password,
      }));
    } catch (err) {
      if (err instanceof InstallLimitError) {
        return reply.code(429).send({ error: 'install_account_limit' });
      }
      throw err;
    }
    if (superseded.length > 0) hooks.onAccountsRemoved(superseded);
    hooks.onAccountUpserted(account);
    return reply.code(204).send();
  });

  app.delete('/v1/accounts', async (request, reply) => {
    const parsed = deleteAccountSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply
        .code(400)
        .send({ error: 'invalid_request', issues: parsed.error.issues });
    }
    const id = repo.deleteAccount(
      parsed.data.pushToken,
      parsed.data.clientAccountId,
    );
    if (id !== null) hooks.onAccountsRemoved([id]);
    return reply.code(204).send();
  });

  // Mail çevirisi. Gövde mail metni içerir: loglanmaz (logger kapalı).
  app.post('/v1/translate', { bodyLimit: 4 * 1024 * 1024 }, async (request, reply) => {
    const parsed = translateSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply
        .code(400)
        .send({ error: 'invalid_request', issues: parsed.error.issues });
    }
    if (!opts.translation) {
      return reply.code(503).send({ error: 'TRANSLATION_UNAVAILABLE' });
    }
    const outcome = await opts.translation.translate({
      ...parsed.data,
      userId: request.installId,
    });
    if (!outcome.ok) {
      return reply.code(outcome.status).send({ error: outcome.code });
    }
    return reply.send({
      translatedSubject: outcome.translatedSubject,
      segments: outcome.segments,
      cacheHit: outcome.cacheHit,
      nearLimit: outcome.nearLimit,
    });
  });

  // Kaynak dil algılama (mail açılınca "Türkçeye Çevir" düğmesine karar vermek
  // için). Örnek metin loglanmaz.
  app.post('/v1/translate/detect', async (request, reply) => {
    const parsed = detectSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply
        .code(400)
        .send({ error: 'invalid_request', issues: parsed.error.issues });
    }
    if (!opts.translation) {
      return reply.code(503).send({ error: 'TRANSLATION_UNAVAILABLE' });
    }
    const outcome = await opts.translation.detect({
      ...parsed.data,
      userId: request.installId,
    });
    if (!outcome.ok) {
      return reply.code(outcome.status).send({ error: outcome.code });
    }
    return reply.send({
      language: outcome.language,
      score: outcome.score,
      nearLimit: outcome.nearLimit,
    });
  });

  app.delete('/v1/devices', async (request, reply) => {
    const parsed = deleteDeviceSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply
        .code(400)
        .send({ error: 'invalid_request', issues: parsed.error.issues });
    }
    const ids = repo.deleteDevice(parsed.data.pushToken);
    if (ids.length > 0) hooks.onAccountsRemoved(ids);
    return reply.code(204).send();
  });

  return app;
}
