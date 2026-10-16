import type Database from 'better-sqlite3';
import { mkdirSync, readdirSync, renameSync, rmSync, statSync } from 'node:fs';
import { join } from 'node:path';

const PREFIX = 'kaydet-';
const SUFFIX = '.sqlite';

/** `kaydet-20260930-143005.sqlite` (UTC); ada göre sıralama = zamana göre sıralama. */
export function backupFileName(now: Date): string {
  const p = (n: number, w = 2) => String(n).padStart(w, '0');
  const stamp =
    `${now.getUTCFullYear()}${p(now.getUTCMonth() + 1)}${p(now.getUTCDate())}` +
    `-${p(now.getUTCHours())}${p(now.getUTCMinutes())}${p(now.getUTCSeconds())}`;
  return `${PREFIX}${stamp}${SUFFIX}`;
}

/**
 * Canlı veritabanının tutarlı bir kopyasını `dir` içine yazar.
 *
 * Dosyayı kopyalamak WAL modunda tutarsız yedek verebilir; `VACUUM INTO`
 * ise tek bir okuma işlemi içinde tutarlı, sıkıştırılmış bir kopya üretir ve
 * yazanları engellemez. Önce geçici ada yazılıp yeniden adlandırılır, böylece
 * yarım kalan bir yedek geçerli yedek gibi görünmez.
 *
 * Dönen değer: yedek dosyasının yolu.
 */
export function backupDatabase(db: Database.Database, dir: string, now = new Date()): string {
  mkdirSync(dir, { recursive: true });
  const finalPath = join(dir, backupFileName(now));
  const tmpPath = `${finalPath}.tmp`;
  rmSync(tmpPath, { force: true });
  try {
    db.prepare('VACUUM INTO ?').run(tmpPath);
    renameSync(tmpPath, finalPath);
  } catch (err) {
    rmSync(tmpPath, { force: true });
    throw err;
  }
  return finalPath;
}

/** En yeni `keep` yedeği bırakır, daha eskileri siler; silinen sayısını döndürür. */
export function pruneBackups(dir: string, keep: number): number {
  const files = readdirSync(dir)
    .filter((f) => f.startsWith(PREFIX) && f.endsWith(SUFFIX))
    .sort();
  const stale = files.slice(0, Math.max(0, files.length - Math.max(1, keep)));
  for (const f of stale) rmSync(join(dir, f), { force: true });
  return stale.length;
}

export interface BackupSchedulerOptions {
  db: Database.Database;
  dir: string;
  intervalMs: number;
  keep: number;
  log?: (message: string) => void;
}

/**
 * Açılışta bir kez, sonra her `intervalMs`'de bir yedek alır. Hata sunucuyu
 * düşürmez (yedek sorunu push'u durdurmamalı) ama `console.error` ile görünür.
 * `VACUUM INTO` eşzamanlıdır: küçük veritabanlarında milisaniyeler sürer,
 * çok büyürse event loop'u kısa süre bloklar.
 */
export class BackupScheduler {
  private timer: NodeJS.Timeout | null = null;
  private readonly log: (message: string) => void;

  constructor(private readonly opts: BackupSchedulerOptions) {
    this.log = opts.log ?? (() => {});
  }

  start(): void {
    this.runOnce();
    this.timer = setInterval(() => this.runOnce(), this.opts.intervalMs);
    this.timer.unref();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  runOnce(): void {
    try {
      const path = backupDatabase(this.opts.db, this.opts.dir);
      const pruned = pruneBackups(this.opts.dir, this.opts.keep);
      const kb = Math.round(statSync(path).size / 1024);
      this.log(`Yedek alındı: ${path} (${kb} KB), silinen eski yedek: ${pruned}`);
    } catch (err) {
      console.error('YEDEK ALINAMADI:', err);
    }
  }
}
