import { readFileSync } from 'node:fs';
import { ApnsClient } from './apns.js';
import { buildApp } from './app.js';
import { loadConfig } from './config.js';
import { SecretBox } from './crypto.js';
import { openDatabase } from './db.js';
import { Notifier } from './notifier.js';
import { Repository } from './repository.js';
import { WatcherManager } from './watcher.js';

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
  const repo = new Repository(db, new SecretBox(config.ENCRYPTION_KEY));

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

  let watchers: WatcherManager;
  const notifier = new Notifier(repo, apns, {
    onDevicesRemoved: (ids) => watchers.onAccountsRemoved(ids),
    log: (message) => console.log(message),
  });
  watchers = new WatcherManager({
    repo,
    notifier,
    log: (message) => console.log(message),
  });

  const app = buildApp({ repo, apiKey: config.API_KEY, hooks: watchers });

  await app.listen({ port: config.PORT, host: config.HOST });
  console.log(`Kaydet push backend dinliyor: ${config.HOST}:${config.PORT}`);
  watchers.startAll();

  const shutdown = async () => {
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
