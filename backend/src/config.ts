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
  APNS_KEY_PATH: z.string().optional(),
  APNS_KEY_PEM: z.string().optional(),
  APNS_KEY_ID: z.string().min(1),
  APNS_TEAM_ID: z.string().min(1),
  APNS_BUNDLE_ID: z.string().default('tr.com.pazarlik.kaydet'),
}).refine(
  (data) =>
    (data.APNS_KEY_PATH != null && data.APNS_KEY_PATH.trim().length > 0) ||
    (data.APNS_KEY_PEM != null && data.APNS_KEY_PEM.trim().length > 0),
  { message: 'APNS_KEY_PATH veya APNS_KEY_PEM en az biri tanımlanmalı' },
);

export type Config = z.infer<typeof schema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  console.log('--- Kaydet Konfigürasyon Kontrolü ---');
  console.log('PORT:', env.PORT || 'varsayılan (8080)');
  console.log('HOST:', env.HOST || 'varsayılan (0.0.0.0)');
  console.log('API_KEY mevcut mu:', !!env.API_KEY);
  console.log('ENCRYPTION_KEY mevcut mu:', !!env.ENCRYPTION_KEY);
  console.log('APNS_KEY_ID mevcut mu:', !!env.APNS_KEY_ID);
  console.log('APNS_KEY_PEM mevcut mu:', !!env.APNS_KEY_PEM);
  console.log('APNS_KEY_PATH mevcut mu:', !!env.APNS_KEY_PATH);

  const parsed = schema.safeParse(env);
  if (!parsed.success) {
    const details = parsed.error.issues
      .map((i) => `  ${i.path.join('.')}: ${i.message}`)
      .join('\n');
    console.error('GEÇERSİZ ORTAM DEĞİŞKENLERİ:\n' + details);
    throw new Error(`Geçersiz ortam değişkenleri:\n${details}`);
  }
  return parsed.data;
}
