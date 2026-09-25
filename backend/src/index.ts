import { ApnsClient } from './apns.js';
import { buildApp } from './app.js';
import { loadConfig } from './config.js';
import { SecretBox } from './crypto.js';
import { openDatabase } from './db.js';
import { Notifier } from './notifier.js';
import { Repository } from './repository.js';
import { WatcherManager } from './watcher.js';

const config = loadConfig();
const db = openDatabase(config.DATABASE_PATH);
const repo = new Repository(db, new SecretBox(config.ENCRYPTION_KEY));

const apns = ApnsClient.fromKeyFile(config.APNS_KEY_PATH, {
  keyId: config.APNS_KEY_ID,
  teamId: config.APNS_TEAM_ID,
  topic: config.APNS_BUNDLE_ID,
});

// `Notifier` ile `WatcherManager` birbirine döngüsel bağlı: geçersiz token
// cihazı silince ilgili izleyiciler de durmalı.
let watchers: WatcherManager;
const notifier = new Notifier(repo, apns, {
  onDevicesRemoved: (ids) => watchers.onAccountsRemoved(ids),
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
