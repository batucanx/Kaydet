import 'dotenv/config';
import { z } from 'zod';

const schema = z.object({
  PORT: z.coerce.number().int().default(8080),
  HOST: z.string().default('0.0.0.0'),
  API_KEY: z.string().min(32, 'API_KEY en az 32 karakter olmalı'),
  ENCRYPTION_KEY: z
    .string()
    .regex(/^[0-9a-fA-F]{64}$/, 'ENCRYPTION_KEY 64 haneli hex olmalı'),
  DATABASE_PATH: z.string().default('./data/kaydet.sqlite'),
  APNS_KEY_PATH: z.string().min(1),
  APNS_KEY_ID: z.string().min(1),
  APNS_TEAM_ID: z.string().min(1),
  APNS_BUNDLE_ID: z.string().default('tr.com.pazarlik.kaydet'),
});

export type Config = z.infer<typeof schema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const parsed = schema.safeParse(env);
  if (!parsed.success) {
    const details = parsed.error.issues
      .map((i) => `  ${i.path.join('.')}: ${i.message}`)
      .join('\n');
    throw new Error(`Geçersiz ortam değişkenleri:\n${details}`);
  }
  return parsed.data;
}
