import type Database from 'better-sqlite3';
import type { SecretBox } from './crypto.js';
import type { AccountRow, ApnsEnvironment, DevicePlatform, DeviceRow } from './db.js';

/** Kurulum başına hesap sınırı aşıldı (izleyici/IDLE kaynağını korur). */
export class InstallLimitError extends Error {
  constructor(readonly limit: number) {
    super(`Kurulum başına en çok ${limit} hesap kaydedilebilir`);
  }
}

export const DEFAULT_MAX_ACCOUNTS_PER_INSTALL = 25;

export interface AccountInput {
  /** Doğrulanmış kurulum kimliği (bkz. installs.ts); cihaz satırına yazılır. */
  installId: string;
  /** iOS'ta APNs, Android'de FCM token'ı. */
  pushToken: string;
  platform: DevicePlatform;
  /** Android'de her zaman `production`. */
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
    private readonly maxAccountsPerInstall = DEFAULT_MAX_ACCOUNTS_PER_INSTALL,
  ) {}

  /** Cihazı ve hesabı kaydeder; aynı (cihaz, hesap) çifti tekrar gelirse günceller. */
  upsertAccount(input: AccountInput): AccountRow {
    const now = Date.now();
    const tx = this.db.transaction((): AccountRow => {
      // Yeniden kurulumda aynı token yeni kuruluma geçebilir: son yazan sahiptir.
      this.db
        .prepare(
          `INSERT INTO devices (push_token, platform, environment, created_at, install_id)
           VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(push_token) DO UPDATE SET
             platform = excluded.platform,
             environment = excluded.environment,
             install_id = excluded.install_id`,
        )
        .run(input.pushToken, input.platform, input.environment, now, input.installId);
      const device = this.db
        .prepare('SELECT * FROM devices WHERE push_token = ?')
        .get(input.pushToken) as DeviceRow;

      const exists = this.db
        .prepare('SELECT 1 FROM accounts WHERE device_id = ? AND client_account_id = ?')
        .get(device.id, input.clientAccountId);
      if (!exists) {
        const { n } = this.db
          .prepare(
            `SELECT COUNT(*) AS n FROM accounts a JOIN devices d ON d.id = a.device_id
             WHERE d.install_id = ?`,
          )
          .get(input.installId) as { n: number };
        if (n >= this.maxAccountsPerInstall) {
          throw new InstallLimitError(this.maxAccountsPerInstall);
        }
      }

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
  deleteAccount(pushToken: string, clientAccountId: number): number | null {
    const row = this.db
      .prepare(
        `SELECT a.id FROM accounts a JOIN devices d ON d.id = a.device_id
         WHERE d.push_token = ? AND a.client_account_id = ?`,
      )
      .get(pushToken, clientAccountId) as { id: number } | undefined;
    if (!row) return null;
    this.db.prepare('DELETE FROM accounts WHERE id = ?').run(row.id);
    return row.id;
  }

  /** Cihazı ve tüm hesaplarını siler; silinen hesap id'lerini döndürür. */
  deleteDevice(pushToken: string): number[] {
    const ids = this.db
      .prepare(
        `SELECT a.id FROM accounts a JOIN devices d ON d.id = a.device_id
         WHERE d.push_token = ?`,
      )
      .all(pushToken) as { id: number }[];
    this.db.prepare('DELETE FROM devices WHERE push_token = ?').run(pushToken);
    return ids.map((r) => r.id);
  }

  listAccounts(): AccountRow[] {
    return this.db.prepare('SELECT * FROM accounts').all() as AccountRow[];
  }

  /** Cihazın sunucuda kayıtlı hesaplarının client_account_id listesini döndürür. */
  listAccountClientIds(pushToken: string): number[] {
    const rows = this.db
      .prepare(
        `SELECT a.client_account_id FROM accounts a
         JOIN devices d ON d.id = a.device_id
         WHERE d.push_token = ?`,
      )
      .all(pushToken) as { client_account_id: number }[];
    return rows.map((r) => r.client_account_id);
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

  updateDeviceEnvironment(deviceId: number, environment: ApnsEnvironment): void {
    this.db
      .prepare('UPDATE devices SET environment = ? WHERE id = ?')
      .run(environment, deviceId);
  }
}
