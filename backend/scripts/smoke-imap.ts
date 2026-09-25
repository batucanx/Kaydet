// IMAP izleyicisini gerçek bir hesapla dener; APNs'e GERÇEK istek atmaz,
// gönderilecek bildirimi ekrana yazar. Kimlik bilgileri .env'den okunur.
import 'dotenv/config';
import { SecretBox } from '../src/crypto.js';
import { openDatabase } from '../src/db.js';
import { Notifier } from '../src/notifier.js';
import { Repository } from '../src/repository.js';
import { AccountWatcher } from '../src/watcher.js';

function need(name: string): string {
  const value = process.env[name];
  if (!value) {
    console.error(`Eksik ortam değişkeni: ${name} (.env dosyasına ekle)`);
    process.exit(1);
  }
  return value;
}

const host = need('SMOKE_IMAP_HOST');
const port = Number(process.env.SMOKE_IMAP_PORT ?? 993);
const secure = (process.env.SMOKE_IMAP_SECURE ?? 'true') !== 'false';
const username = need('SMOKE_IMAP_USER');
const password = need('SMOKE_IMAP_PASS');

const db = openDatabase(':memory:');
const repo = new Repository(db, new SecretBox('0'.repeat(64)));
const account = repo.upsertAccount({
  apnsToken: 'ab'.repeat(32),
  environment: 'development',
  clientAccountId: 1,
  host,
  port,
  secure,
  username,
  password,
});

const stamp = () => new Date().toISOString().slice(11, 23);

const notifier = new Notifier(
  repo,
  {
    async send(_token, _env, payload) {
      const alert = payload.aps.alert as { title: string; body: string };
      console.log(
        `[${stamp()}] BİLDİRİM -> "${alert.title}" / "${alert.body}" ` +
          `(rozet: ${String(payload.aps.badge)})`,
      );
      return { status: 'sent' };
    },
  },
);

const watcher = new AccountWatcher(account, {
  repo,
  notifier,
  log: (message) => console.log(`[${stamp()}] ${message}`),
  onAuthFailed: () => {
    console.error('Kimlik doğrulama başarısız: kullanıcı adı/şifreyi kontrol et.');
    process.exit(1);
  },
});

console.log(`[${stamp()}] ${username} @ ${host}:${port} izleniyor...`);
console.log('Şimdi bu hesaba başka bir yerden (web client) mail at. Çıkış: Ctrl+C');
watcher.start();

process.on('SIGINT', async () => {
  await watcher.stop();
  process.exit(0);
});
