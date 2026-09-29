import Fastify, { type FastifyInstance } from 'fastify';
import { timingSafeEqual } from 'node:crypto';
import { z } from 'zod';
import type { AccountRow } from './db.js';
import type { Repository } from './repository.js';
import type { TranslationService } from './translation.js';

/** İzleyici (IDLE) katmanının hesap değişikliklerinden haberdar olması için. */
export interface AccountHooks {
  onAccountUpserted(account: AccountRow): void;
  onAccountsRemoved(accountIds: number[]): void;
}

const noopHooks: AccountHooks = {
  onAccountUpserted() {},
  onAccountsRemoved() {},
};

// APNs cihaz token'ı: 32 bayt = 64 hex; Apple ileride uzatabilir.
const tokenSchema = z
  .string()
  .regex(/^[0-9a-fA-F]{64,200}$/, 'Geçersiz APNs token')
  .transform((t) => t.toLowerCase());

const upsertSchema = z.object({
  apnsToken: tokenSchema,
  environment: z.enum(['development', 'production']),
  clientAccountId: z.number().int().nonnegative(),
  imap: z.object({
    host: z.string().min(1).max(255),
    port: z.number().int().min(1).max(65535),
    secure: z.boolean(),
  }),
  username: z.string().min(1).max(320),
  password: z.string().min(1).max(1024),
});

const deleteAccountSchema = z.object({
  apnsToken: tokenSchema,
  clientAccountId: z.number().int().nonnegative(),
});

const deleteDeviceSchema = z.object({ apnsToken: tokenSchema });

const languageSchema = z.string().regex(/^[a-zA-Z]{2,3}(-[a-zA-Z0-9]{2,8})*$/);

const translateSchema = z.object({
  // Kullanıcı bazlı kota için kararlı, istemciye özel kimlik (bkz. app tarafı).
  userId: z.string().min(8).max(128),
  messageId: z.string().min(1).max(200),
  // `auto`: kaynak dil sağlayıcıya bırakılır.
  sourceLanguage: z.union([z.literal('auto'), languageSchema]),
  targetLanguage: languageSchema,
  subject: z.string().max(100_000),
  segments: z.array(z.string().max(100_000)).max(20_000),
});

const detectSchema = z.object({
  userId: z.string().min(8).max(128),
  sample: z.string().max(20_000),
});

function safeEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  return ab.length === bb.length && timingSafeEqual(ab, bb);
}

export function buildApp(opts: {
  repo: Repository;
  apiKey: string;
  hooks?: AccountHooks;
  /** Verilmezse `/v1/translate` TRANSLATION_UNAVAILABLE döner. */
  translation?: TranslationService;
}): FastifyInstance {
  const { repo, apiKey } = opts;
  const hooks = opts.hooks ?? noopHooks;
  // İstek gövdeleri şifre içerir; istek loglaması bilerek kapalı.
  const app = Fastify({ logger: false });

  app.get('/health', async () => ({ ok: true }));

  app.addHook('preHandler', async (request, reply) => {
    if (request.url === '/health') return;
    const header = request.headers.authorization ?? '';
    const token = header.startsWith('Bearer ') ? header.slice(7) : '';
    if (!safeEqual(token, apiKey)) {
      return reply.code(401).send({ error: 'unauthorized' });
    }
  });

  const tokenQuerySchema = z.object({
    apnsToken: tokenSchema,
  });

  app.get('/v1/accounts', async (request, reply) => {
    const parsed = tokenQuerySchema.safeParse(request.query);
    if (!parsed.success) {
      return reply
        .code(400)
        .send({ error: 'invalid_request', issues: parsed.error.issues });
    }
    const clientAccountIds = repo.listAccountClientIds(parsed.data.apnsToken);
    return reply.send({ clientAccountIds });
  });

  app.put('/v1/accounts', async (request, reply) => {
    const parsed = upsertSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply
        .code(400)
        .send({ error: 'invalid_request', issues: parsed.error.issues });
    }
    const b = parsed.data;
    const account = repo.upsertAccount({
      apnsToken: b.apnsToken,
      environment: b.environment,
      clientAccountId: b.clientAccountId,
      host: b.imap.host,
      port: b.imap.port,
      secure: b.imap.secure,
      username: b.username,
      password: b.password,
    });
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
      parsed.data.apnsToken,
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
    const outcome = await opts.translation.translate(parsed.data);
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
    const outcome = await opts.translation.detect(parsed.data);
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
    const ids = repo.deleteDevice(parsed.data.apnsToken);
    if (ids.length > 0) hooks.onAccountsRemoved(ids);
    return reply.code(204).send();
  });

  return app;
}
