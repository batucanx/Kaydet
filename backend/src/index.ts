import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { BackupScheduler } from './backup.js';
import { ApnsClient } from './apns.js';
import { FcmClient, parseServiceAccount } from './fcm.js';
import { buildApp } from './app.js';
import { InstallRegistry } from './installs.js';
import { loadConfig } from './config.js';
import { SecretBox } from './crypto.js';
import { openDatabase } from './db.js';
import { Notifier } from './notifier.js';
import { Repository } from './repository.js';
import { WatcherManager } from './watcher.js';
import { AzureTranslatorProvider } from './azure-translator.js';
import { defaultBatchLimits, TranslationService, TranslationStore } from './translation.js';

process.on('uncaughtException', (err) => {
  console.error('Kritik Yakalanmamış Hata (uncaughtException):', err);
});
process.on('unhandledRejection', (reason) => {
  console.error('Kritik Yakalanmamış Promise Hatası (unhandledRejection):', reason);
});

try {
  console.log('Kaydet push backend başlatılıyor...');
  const config = loadConfig();
  console.log('Konfigürasyon doğrulandı. Veritabanı açılıyor...');
  const db = openDatabase(config.DATABASE_PATH);
  console.log('Veritabanı hazır. APNs istemcisi kuruluyor...');
  const repo = new Repository(
    db,
    new SecretBox(config.ENCRYPTION_KEY),
    config.MAX_ACCOUNTS_PER_INSTALL,
  );

  console.log('APNs PEM/Base64 anahtarı çözümleniyor...');
  const keyPem = config.APNS_KEY_PEM?.trim()
    ? (config.APNS_KEY_PEM.includes('-----BEGIN')
        ? config.APNS_KEY_PEM
        : Buffer.from(config.APNS_KEY_PEM, 'base64').toString('utf8'))
    : readFileSync(config.APNS_KEY_PATH!, 'utf8');

  console.log('ApnsClient örneği oluşturuluyor...');
  const apns = new ApnsClient({
    keyPem,
    keyId: config.APNS_KEY_ID,
    teamId: config.APNS_TEAM_ID,
    topic: config.APNS_BUNDLE_ID,
  });

  console.log('Apple APNs ile anahtar doğrulaması (verifyKey) yapılıyor...');
  await apns.verifyKey();
  console.log(
    `APNs anahtarı başarıyla doğrulandı (Key ID: ${config.APNS_KEY_ID}, Team ID: ${config.APNS_TEAM_ID}, ` +
      `topic: ${config.APNS_BUNDLE_ID})`,
  );

  const fcmRaw = config.FCM_SERVICE_ACCOUNT?.trim()
    ? config.FCM_SERVICE_ACCOUNT
    : config.FCM_SERVICE_ACCOUNT_PATH?.trim()
      ? readFileSync(config.FCM_SERVICE_ACCOUNT_PATH, 'utf8')
      : null;
  let fcm: FcmClient | undefined;
  if (fcmRaw) {
    fcm = new FcmClient({ account: parseServiceAccount(fcmRaw) });
    await fcm.verifyKey();
    console.log(`FCM anahtarı doğrulandı (proje: ${fcm.projectId})`);
  } else {
    console.warn('FCM yapılandırılmadı: Android kayıtları 503 alacak (iOS etkilenmez)');
  }

  let watchers: WatcherManager;
  const notifier = new Notifier(repo, apns, {
    ...(fcm ? { fcm } : {}),
    onDevicesRemoved: (ids) => watchers.onAccountsRemoved(ids),
    log: (message) => console.log(message),
  });
  watchers = new WatcherManager({
    repo,
    notifier,
    log: (message) => console.log(message),
  });

  const translationStore = new TranslationStore(db);
  // Önceki çalışma yanıt beklerken kapandıysa ayrılmış karakterler harcanmış sayılır.
  translationStore.settleStaleReservations(Date.now());
  translationStore.pruneCache(Date.now() - 90 * 24 * 60 * 60 * 1000);
  const translation = new TranslationService({
    store: translationStore,
    provider:
      config.AZURE_TRANSLATOR_ENABLED && config.AZURE_TRANSLATOR_KEY?.trim()
        ? new AzureTranslatorProvider({
            endpoint:
              config.AZURE_TRANSLATOR_ENDPOINT.trim() ||
              'https://api.cognitive.microsofttranslator.com',
            key: config.AZURE_TRANSLATOR_KEY.trim(),
            region: config.AZURE_TRANSLATOR_REGION?.trim() || undefined,
          })
        : null,
    limits: {
      monthlyLimit: config.AZURE_TRANSLATOR_MONTHLY_LIMIT,
      warningLimit: config.AZURE_TRANSLATOR_WARNING_LIMIT,
      userMonthlyLimit: config.AZURE_TRANSLATOR_USER_MONTHLY_LIMIT,
      maxRequestChars: config.AZURE_TRANSLATOR_MAX_REQUEST_CHARS,
      ...defaultBatchLimits,
    },
    log: (message) => console.log(message),
  });

  const app = buildApp({
    repo,
    installs: new InstallRegistry(db, { newInstallsPerHour: config.INSTALLS_PER_IP_HOUR }),
    apiKey: config.API_KEY,
    hooks: watchers,
    androidPush: fcm !== undefined,
    translation,
    trustProxy: config.TRUST_PROXY,
  });

  await app.listen({ port: config.PORT, host: config.HOST });
  console.log(`Kaydet push backend dinliyor: ${config.HOST}:${config.PORT}`);
  watchers.startAll();

  const backups =
    config.BACKUP_ENABLED && config.DATABASE_PATH !== ':memory:'
      ? new BackupScheduler({
          db,
          dir: config.BACKUP_DIR?.trim() || join(dirname(config.DATABASE_PATH), 'backups'),
          intervalMs: config.BACKUP_INTERVAL_HOURS * 60 * 60 * 1000,
          keep: config.BACKUP_KEEP,
          log: (message) => console.log(message),
        })
      : null;
  backups?.start();

  const shutdown = async () => {
    backups?.stop();
    await app.close();
    await watchers.stopAll();
    apns.close();
    db.close();
    process.exit(0);
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
} catch (error) {
  console.error('FATAL BAŞLATMA HATASI:', error);
  // Logların Railway paneline düşebilmesi için 5 saniye bekle
  await new Promise((resolve) => setTimeout(resolve, 5000));
  process.exit(1);
}
