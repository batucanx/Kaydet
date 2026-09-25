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
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
  const db = new Database(path);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
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
  `);
  return db;
}
