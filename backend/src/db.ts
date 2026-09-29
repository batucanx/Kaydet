import Database from 'better-sqlite3';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

export type ApnsEnvironment = 'development' | 'production';

export interface DeviceRow {
  id: number;
  apns_token: string;
  environment: ApnsEnvironment;
  created_at: number;
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
    console.error('Database dosyası açılamadı, :memory: deneniyor:', err);
    db = new Database(':memory:');
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
      apns_token TEXT NOT NULL UNIQUE,
      environment TEXT NOT NULL CHECK (environment IN ('development','production')),
      created_at INTEGER NOT NULL
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
  return db;
}
