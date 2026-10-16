import type Database from 'better-sqlite3';
import { createHash, timingSafeEqual } from 'node:crypto';

export const INSTALL_ID_PATTERN = /^[0-9a-f]{32,64}$/;
export const INSTALL_SECRET_PATTERN = /^[0-9a-f]{32,128}$/;

export type InstallCheck = 'ok' | 'bad_secret' | 'rate_limited';

const sha256 = (value: string) => createHash('sha256').update(value).digest('hex');

function safeEqualHex(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  return ab.length === bb.length && timingSafeEqual(ab, bb);
}

/**
 * Kurulum (install) kimlikleri: uygulama ilk açılışta rastgele bir `installId`
 * ve `installSecret` üretir, her istekte ikisini de gönderir.
 *
 * - Sunucu ilk görüşte (trust on first use) `sha256(secret)` saklar; sonraki
 *   isteklerde sabit zamanlı karşılaştırır. Sır düz saklanmaz.
 * - Yeni kurulum kaydı IP başına saatte `newInstallsPerHour` ile sınırlıdır;
 *   böylece paylaşılan API anahtarını çıkaran biri sınırsız kimlik üretemez.
 *
 * Bu, kötü niyetli betiği TAMAMEN durdurmaz (her yeni kimlik ucuzdur); amacı
 * kotaları ve limitleri istemcinin seçtiği bir metne değil, sunucunun
 * doğruladığı bir kimliğe bağlamak ve kötüye kullanımı IP başına yavaşlatmaktır.
 * Gerçek cihaz kanıtı için App Attest / Play Integrity gerekir.
 */
export class InstallRegistry {
  private readonly windows = new Map<string, { count: number; resetAt: number }>();

  constructor(
    private readonly db: Database.Database,
    private readonly opts: { newInstallsPerHour: number; now?: () => number } = {
      newInstallsPerHour: 30,
    },
  ) {}

  private now(): number {
    return this.opts.now?.() ?? Date.now();
  }

  check(installId: string, secret: string, ip: string): InstallCheck {
    const hash = sha256(secret);
    const row = this.db
      .prepare('SELECT secret_hash, last_seen_at FROM installs WHERE install_id = ?')
      .get(installId) as { secret_hash: string; last_seen_at: number } | undefined;
    const now = this.now();

    if (row) {
      if (!safeEqualHex(row.secret_hash, hash)) return 'bad_secret';
      // Her istekte yazmamak için en çok saatte bir güncellenir.
      if (now - row.last_seen_at > 3_600_000) {
        this.db
          .prepare('UPDATE installs SET last_seen_at = ? WHERE install_id = ?')
          .run(now, installId);
      }
      return 'ok';
    }

    if (!this.allowNewInstall(ip, now)) return 'rate_limited';
    this.db
      .prepare(
        'INSERT INTO installs (install_id, secret_hash, created_at, last_seen_at) VALUES (?, ?, ?, ?)',
      )
      .run(installId, hash, now, now);
    return 'ok';
  }

  private allowNewInstall(ip: string, now: number): boolean {
    if (this.windows.size > 10_000) {
      for (const [key, w] of this.windows) if (w.resetAt <= now) this.windows.delete(key);
    }
    const w = this.windows.get(ip);
    if (!w || w.resetAt <= now) {
      this.windows.set(ip, { count: 1, resetAt: now + 3_600_000 });
      return true;
    }
    if (w.count >= this.opts.newInstallsPerHour) return false;
    w.count += 1;
    return true;
  }
}
