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
  // Kurulum doğrulaması (bkz. installs.ts). Ters vekil (Railway vb.) arkasında
  // TRUST_PROXY=true olmalı, yoksa tüm istekler vekilin IP'sinden görünür ve IP
  // başına limit herkesi ortak sayar. Vekil yoksa false yapın (başlık taklit edilebilir).
  TRUST_PROXY: z
    .enum(['true', 'false'])
    .default('true')
    .transform((v) => v === 'true'),
  INSTALLS_PER_IP_HOUR: z.coerce.number().int().positive().default(30),
  MAX_ACCOUNTS_PER_INSTALL: z.coerce.number().int().positive().default(25),

  // Düzenli SQLite yedeği (VACUUM INTO). BACKUP_DIR boşsa veritabanının
  // yanındaki `backups/` kullanılır. BACKUP_ENABLED=false kapatır.
  BACKUP_ENABLED: z
    .enum(['true', 'false'])
    .default('true')
    .transform((v) => v === 'true'),
  BACKUP_DIR: z.string().optional(),
  BACKUP_INTERVAL_HOURS: z.coerce.number().positive().default(24),
  BACKUP_KEEP: z.coerce.number().int().positive().default(7),
  APNS_KEY_PATH: z.string().optional(),
  APNS_KEY_PEM: z.string().optional(),
  APNS_KEY_ID: z.string().min(1),
  APNS_TEAM_ID: z.string().min(1),
  APNS_BUNDLE_ID: z.string().default('tr.com.pazarlik.kaydet'),

  // Android push (Firebase Cloud Messaging HTTP v1). Firebase Console →
  // Proje ayarları → Hizmet hesapları → "Yeni özel anahtar oluştur" ile inen
  // JSON, ham ya da base64 olarak FCM_SERVICE_ACCOUNT'a (veya dosya yolu
  // FCM_SERVICE_ACCOUNT_PATH'e) verilir. İkisi de boşsa Android kayıtları
  // 503 `android_push_unavailable` alır; iOS etkilenmez.
  FCM_SERVICE_ACCOUNT: z.string().optional(),
  FCM_SERVICE_ACCOUNT_PATH: z.string().optional(),

  // Mail çevirisi (Azure AI Translator, F0 ücretsiz katman: 2.000.000
  // karakter/ay). Kapalıysa ya da anahtar yoksa çeviri uç noktaları
  // TRANSLATION_UNAVAILABLE döner; diğer özellikler etkilenmez. Limitler
  // ücretsiz kotanın ALTINDA tutulur (ölçüm farkları ve eşzamanlı istekler için
  // güvenlik payı). Geliştirmede `AZURE_TRANSLATOR_MONTHLY_LIMIT=10000` gibi
  // küçük bir değerle denenebilir.
  AZURE_TRANSLATOR_ENABLED: z
    .enum(['true', 'false'])
    .default('true')
    .transform((v) => v === 'true'),
  AZURE_TRANSLATOR_ENDPOINT: z.string().default('https://api.cognitive.microsofttranslator.com'),
  AZURE_TRANSLATOR_KEY: z.string().optional(),
  AZURE_TRANSLATOR_REGION: z.string().optional(),
  AZURE_TRANSLATOR_MONTHLY_LIMIT: z.coerce.number().int().nonnegative().default(1_800_000),
  AZURE_TRANSLATOR_WARNING_LIMIT: z.coerce.number().int().nonnegative().default(1_600_000),
  AZURE_TRANSLATOR_USER_MONTHLY_LIMIT: z.coerce.number().int().nonnegative().default(200_000),
  AZURE_TRANSLATOR_MAX_REQUEST_CHARS: z.coerce.number().int().positive().default(100_000),
})
  .refine(
    (data) =>
      (data.APNS_KEY_PATH != null && data.APNS_KEY_PATH.trim().length > 0) ||
      (data.APNS_KEY_PEM != null && data.APNS_KEY_PEM.trim().length > 0),
    { message: 'APNS_KEY_PATH veya APNS_KEY_PEM en az biri tanımlanmalı' },
  )
  .refine(
    (data) => data.AZURE_TRANSLATOR_WARNING_LIMIT <= data.AZURE_TRANSLATOR_MONTHLY_LIMIT,
    {
      message: 'AZURE_TRANSLATOR_WARNING_LIMIT, AZURE_TRANSLATOR_MONTHLY_LIMIT değerini aşamaz',
      path: ['AZURE_TRANSLATOR_WARNING_LIMIT'],
    },
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
