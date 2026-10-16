import { mkdirSync, mkdtempSync, readdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import Database from 'better-sqlite3';
import { describe, expect, it } from 'vitest';
import { backupDatabase, backupFileName, pruneBackups } from '../src/backup.js';
import { openDatabase } from '../src/db.js';

const tmp = () => mkdtempSync(join(tmpdir(), 'kaydet-yedek-'));

describe('backupDatabase', () => {
  it('canlı veritabanının açılabilir, aynı veriyi içeren kopyasını üretir', () => {
    const dir = tmp();
    const db = openDatabase(join(dir, 'k.sqlite'));
    db.prepare("insert into devices (push_token, environment, created_at) values ('t1','production',1)").run();

    const path = backupDatabase(db, join(dir, 'backups'), new Date('2026-09-30T14:30:05Z'));
    expect(path.endsWith('kaydet-20260930-143005.sqlite')).toBe(true);

    const copy = new Database(path, { readonly: true });
    expect(copy.prepare('select push_token from devices').all()).toEqual([{ push_token: 't1' }]);
    copy.close();
    db.close();
  });

  it('geçici .tmp dosyası bırakmaz', () => {
    const dir = tmp();
    const db = openDatabase(':memory:');
    backupDatabase(db, dir);
    expect(readdirSync(dir).some((f) => f.endsWith('.tmp'))).toBe(false);
  });

  it('aynı saniyede ikinci kez çalışınca üzerine yazar, hata vermez', () => {
    const dir = tmp();
    const db = openDatabase(':memory:');
    const now = new Date('2026-09-30T14:30:05Z');
    backupDatabase(db, dir, now);
    expect(() => backupDatabase(db, dir, now)).not.toThrow();
  });
});

describe('pruneBackups', () => {
  it('en yeni N yedeği bırakır, yalnızca yedek dosyalarına dokunur', () => {
    const dir = tmp();
    mkdirSync(dir, { recursive: true });
    for (const d of [1, 2, 3, 4, 5]) {
      writeFileSync(join(dir, backupFileName(new Date(Date.UTC(2026, 8, d)))), 'x');
    }
    writeFileSync(join(dir, 'baska.txt'), 'x');

    expect(pruneBackups(dir, 2)).toBe(3);
    expect(readdirSync(dir).sort()).toEqual([
      'baska.txt',
      backupFileName(new Date(Date.UTC(2026, 8, 4))),
      backupFileName(new Date(Date.UTC(2026, 8, 5))),
    ]);
  });

  it('keep 0 verilse bile en az bir yedek bırakır', () => {
    const dir = tmp();
    writeFileSync(join(dir, backupFileName(new Date(Date.UTC(2026, 8, 1)))), 'x');
    expect(pruneBackups(dir, 0)).toBe(0);
  });
});
