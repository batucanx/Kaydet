import Database from 'better-sqlite3';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

export type ApnsEnvironment = 'development' | 'production';
export type DevicePlatform = 'ios' | 'android';

export interface DeviceRow {
  id: number;
  /** iOS'ta APNs, Android'de FCM kayıt token'ı. */
  push_token: string;
  platform: DevicePlatform;
  /** Yalnızca iOS için anlamlı; Android satırlarında `production` yazılır. */
  environment: ApnsEnvironment;
  created_at: number;
  install_id: string | null;
}

export interface AccountRow {
  id: number;
  device_id: number;
  // İstemcideki hesap kimliği; bildirime dokununca doğru hesabı açmak için.
  client_account_id: number;
  imap_host: string;
  imap_port: number;
  imap_secure: number;
  username: string;
  password_enc: string;
  last_uid: number | null;
  uid_validity: number | null;
  unread: number;
  created_at: number;
}

export function openDatabase(path: string): Database.Database {
  console.log('openDatabase başlatılıyor, yol:', path);
  if (path !== ':memory:') {
    const dir = dirname(path);
    console.log('Veritabanı dizini kontrol ediliyor:', dir);
    mkdirSync(dir, { recursive: true });
  }
  console.log('new Database(path) çağrılıyor...');
  let db: Database.Database;
  try {
    db = new Database(path);
  } catch (err) {
    // Sessizce :memory:'ye düşmek, sunucunun sağlıklı görünüp hiçbir şeyi
    // kalıcı tutmamasına (ve abonelikleri her yeniden başlatmada kaybetmesine)
    // yol açar. Açılamıyorsa süreç hemen, anlaşılır bir hatayla kapanmalı.
    throw new Error(
      `Veritabanı açılamadı (${path}). DATABASE_PATH'in yazılabilir, kalıcı bir ` +
        `diski (Volume) göstermesi gerekir.`,
      { cause: err },
    );
  }
  console.log('Pragma ayarlanıyor...');
  try {
    db.pragma('journal_mode = WAL');
  } catch (e) {
    console.warn('WAL modu başarısız oldu, DELETE deneniyor:', e);
    try {
      db.pragma('journal_mode = DELETE');
    } catch (_) {}
  }
  db.pragma('foreign_keys = ON');
  console.log('Tablo şemaları oluşturuluyor...');
  db.exec(`
    CREATE TABLE IF NOT EXISTS devices (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      push_token TEXT NOT NULL UNIQUE,
      platform TEXT NOT NULL DEFAULT 'ios' CHECK (platform IN ('ios','android')),
      environment TEXT NOT NULL CHECK (environment IN ('development','production')),
      created_at INTEGER NOT NULL
    );
    -- Doğrulanmış uygulama kurulumları (bkz. installs.ts). Sır düz saklanmaz.
    CREATE TABLE IF NOT EXISTS installs (
      install_id TEXT PRIMARY KEY,
      secret_hash TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      last_seen_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS accounts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      device_id INTEGER NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
      client_account_id INTEGER NOT NULL,
      imap_host TEXT NOT NULL,
      imap_port INTEGER NOT NULL,
      imap_secure INTEGER NOT NULL DEFAULT 1,
      username TEXT NOT NULL,
      password_enc TEXT NOT NULL,
      last_uid INTEGER,
      uid_validity INTEGER,
      unread INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      UNIQUE (device_id, client_account_id)
    );

    -- Çeviri kotası: ay ('2026-09') başına ayrı satır; eski aylar geçmiş
    -- kullanım analizi için silinmez. reserved = Azure'a gitmek üzere ayrılmış
    -- (henüz sonuçlanmamış), consumed = harcanmış karakter.
    CREATE TABLE IF NOT EXISTS translation_usage (
      month TEXT PRIMARY KEY,
      reserved_characters INTEGER NOT NULL DEFAULT 0,
      consumed_characters INTEGER NOT NULL DEFAULT 0,
      request_count INTEGER NOT NULL DEFAULT 0,
      updated_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS user_translation_usage (
      user_id TEXT NOT NULL,
      month TEXT NOT NULL,
      reserved_characters INTEGER NOT NULL DEFAULT 0,
      consumed_characters INTEGER NOT NULL DEFAULT 0,
      request_count INTEGER NOT NULL DEFAULT 0,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (user_id, month)
    );
    -- Çeviri önbelleği. Anahtar kullanıcıya da bağlıdır: ileti kimliği
    -- (istemcideki yerel satır no) kullanıcılar arasında çakışabilir, bir
    -- kullanıcı başkasının çevirisini görmemeli. source_hash, aynı anahtar için
    -- içerik değişmişse eski çeviriyi sunmayı önler.
    CREATE TABLE IF NOT EXISTS translated_email_cache (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id TEXT NOT NULL,
      message_id TEXT NOT NULL,
      source_language TEXT NOT NULL,
      target_language TEXT NOT NULL,
      source_hash TEXT NOT NULL,
      translated_subject TEXT NOT NULL,
      translated_segments TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      UNIQUE (user_id, message_id, source_language, target_language)
    );
  `);
  // Eski veritabanlarında `apns_token` adı ve `platform` sütunu yoktur. Tüm
  // eski satırlar iOS'tur. SQLite sütun adını yerinde değiştirir; UNIQUE
  // kısıtı ve dizinler adıyla birlikte taşınır.
  const legacyColumns = db.prepare('PRAGMA table_info(devices)').all() as { name: string }[];
  if (legacyColumns.some((c) => c.name === 'apns_token')) {
    db.exec('ALTER TABLE devices RENAME COLUMN apns_token TO push_token');
  }
  if (!legacyColumns.some((c) => c.name === 'platform')) {
    db.exec("ALTER TABLE devices ADD COLUMN platform TEXT NOT NULL DEFAULT 'ios'");
  }
  // Eski veritabanlarında devices.install_id yoktur; CREATE IF NOT EXISTS
  // mevcut tabloyu değiştirmez. Boş (NULL) kalan satırlar ilk kayıtta sahiplenilir.
  const deviceColumns = db.prepare('PRAGMA table_info(devices)').all() as { name: string }[];
  if (!deviceColumns.some((c) => c.name === 'install_id')) {
    db.exec('ALTER TABLE devices ADD COLUMN install_id TEXT');
  }
  db.exec('CREATE INDEX IF NOT EXISTS idx_devices_install ON devices(install_id)');
  return db;
}
