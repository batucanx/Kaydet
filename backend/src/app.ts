import Fastify, { type FastifyInstance } from 'fastify';
import { timingSafeEqual } from 'node:crypto';
import { z } from 'zod';
import type { AccountRow } from './db.js';
import type { Repository } from './repository.js';

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

function safeEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  return ab.length === bb.length && timingSafeEqual(ab, bb);
}

export function buildApp(opts: {
  repo: Repository;
  apiKey: string;
  hooks?: AccountHooks;
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
