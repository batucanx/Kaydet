import type Database from 'better-sqlite3';
import type { SecretBox } from './crypto.js';
import type { AccountRow, ApnsEnvironment, DeviceRow } from './db.js';

export interface AccountInput {
  apnsToken: string;
  environment: ApnsEnvironment;
  clientAccountId: number;
  host: string;
  port: number;
  secure: boolean;
  username: string;
  password: string;
}

export class Repository {
  constructor(
    private readonly db: Database.Database,
    private readonly box: SecretBox,
  ) {}

  /** Cihazı ve hesabı kaydeder; aynı (cihaz, hesap) çifti tekrar gelirse günceller. */
  upsertAccount(input: AccountInput): AccountRow {
    const now = Date.now();
    const tx = this.db.transaction((): AccountRow => {
      this.db
        .prepare(
          `INSERT INTO devices (apns_token, environment, created_at)
           VALUES (?, ?, ?)
           ON CONFLICT(apns_token) DO UPDATE SET environment = excluded.environment`,
        )
        .run(input.apnsToken, input.environment, now);
      const device = this.db
        .prepare('SELECT * FROM devices WHERE apns_token = ?')
        .get(input.apnsToken) as DeviceRow;

      // Sunucu ya da kullanıcı değişince eski UID artık geçerli olmaz.
      this.db
        .prepare(
          `INSERT INTO accounts
             (device_id, client_account_id, imap_host, imap_port, imap_secure,
              username, password_enc, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT(device_id, client_account_id) DO UPDATE SET
             last_uid = CASE
               WHEN imap_host != excluded.imap_host OR username != excluded.username
               THEN NULL ELSE last_uid END,
             uid_validity = CASE
               WHEN imap_host != excluded.imap_host OR username != excluded.username
               THEN NULL ELSE uid_validity END,
             imap_host = excluded.imap_host,
             imap_port = excluded.imap_port,
             imap_secure = excluded.imap_secure,
             username = excluded.username,
             password_enc = excluded.password_enc`,
        )
        .run(
          device.id,
          input.clientAccountId,
          input.host,
          input.port,
          input.secure ? 1 : 0,
          input.username,
          this.box.encrypt(input.password),
          now,
        );
      return this.db
        .prepare(
          'SELECT * FROM accounts WHERE device_id = ? AND client_account_id = ?',
        )
        .get(device.id, input.clientAccountId) as AccountRow;
    });
    return tx();
  }

  /** Silinen hesabın id'sini döndürür (izleyiciyi durdurmak için); yoksa null. */
  deleteAccount(apnsToken: string, clientAccountId: number): number | null {
    const row = this.db
      .prepare(
        `SELECT a.id FROM accounts a JOIN devices d ON d.id = a.device_id
         WHERE d.apns_token = ? AND a.client_account_id = ?`,
      )
      .get(apnsToken, clientAccountId) as { id: number } | undefined;
    if (!row) return null;
    this.db.prepare('DELETE FROM accounts WHERE id = ?').run(row.id);
    return row.id;
  }

  /** Cihazı ve tüm hesaplarını siler; silinen hesap id'lerini döndürür. */
  deleteDevice(apnsToken: string): number[] {
    const ids = this.db
      .prepare(
        `SELECT a.id FROM accounts a JOIN devices d ON d.id = a.device_id
         WHERE d.apns_token = ?`,
      )
      .all(apnsToken) as { id: number }[];
    this.db.prepare('DELETE FROM devices WHERE apns_token = ?').run(apnsToken);
    return ids.map((r) => r.id);
  }

  listAccounts(): AccountRow[] {
    return this.db.prepare('SELECT * FROM accounts').all() as AccountRow[];
  }

  getAccount(id: number): AccountRow | undefined {
    return this.db.prepare('SELECT * FROM accounts WHERE id = ?').get(id) as
      | AccountRow
      | undefined;
  }

  getDevice(id: number): DeviceRow | undefined {
    return this.db.prepare('SELECT * FROM devices WHERE id = ?').get(id) as
      | DeviceRow
      | undefined;
  }

  setCursor(id: number, lastUid: number, uidValidity: number): void {
    this.db
      .prepare('UPDATE accounts SET last_uid = ?, uid_validity = ? WHERE id = ?')
      .run(lastUid, uidValidity, id);
  }

  setUnread(id: number, unread: number): void {
    this.db
      .prepare('UPDATE accounts SET unread = ? WHERE id = ?')
      .run(Math.max(0, unread), id);
  }

  /** Cihazın rozeti: cihaza bağlı tüm hesapların okunmamış toplamı. */
  deviceUnreadTotal(deviceId: number): number {
    const row = this.db
      .prepare('SELECT COALESCE(SUM(unread), 0) AS total FROM accounts WHERE device_id = ?')
      .get(deviceId) as { total: number };
    return row.total;
  }

  decryptPassword(account: AccountRow): string {
    return this.box.decrypt(account.password_enc);
  }
}
