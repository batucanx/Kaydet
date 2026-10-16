import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { SecretBox } from '../src/crypto.js';
import { openDatabase } from '../src/db.js';

const key = 'a'.repeat(64);

describe('SecretBox', () => {
  it('şifreleyip geri çözer', () => {
    const box = new SecretBox(key);
    const enc = box.encrypt('gizli-şifre');
    expect(enc).not.toContain('gizli');
    expect(box.decrypt(enc)).toBe('gizli-şifre');
  });

  it('her seferinde farklı çıktı üretir', () => {
    const box = new SecretBox(key);
    expect(box.encrypt('x')).not.toBe(box.encrypt('x'));
  });

  it('kurcalanmış veriyi reddeder', () => {
    const box = new SecretBox(key);
    const raw = Buffer.from(box.encrypt('x'), 'base64');
    raw[raw.length - 1]! ^= 1;
    expect(() => box.decrypt(raw.toString('base64'))).toThrow();
  });

  it('yanlış anahtarla çözemez', () => {
    const enc = new SecretBox(key).encrypt('x');
    expect(() => new SecretBox('b'.repeat(64)).decrypt(enc)).toThrow();
  });
});

describe('openDatabase', () => {
  it('şemayı oluşturur', () => {
    const db = openDatabase(':memory:');
    const tables = db
      .prepare("select name from sqlite_master where type='table' and name in ('devices','accounts')")
      .all();
    expect(tables).toHaveLength(2);
  });

  it('açılamayan dosyada :memory:\'ye düşmek yerine hata verir', () => {
    const missing = join(tmpdir(), 'kaydet-yok-' + Date.now(), 'x.sqlite');
    // Üst dizin openDatabase tarafından oluşturulur; bir dosyanın "altına"
    // dizin açmaya çalışarak gerçekten açılamayan bir yol üretiriz.
    const file = join(mkdtempSync(join(tmpdir(), 'kaydet-')), 'dosya');
    writeFileSync(file, 'x');
    expect(() => openDatabase(join(file, 'alt', 'db.sqlite'))).toThrow();
    expect(() => openDatabase(missing)).not.toThrow();
  });

  it('verisini yeniden açıldığında korur', () => {
    const path = join(mkdtempSync(join(tmpdir(), 'kaydet-')), 'k.sqlite');
    const a = openDatabase(path);
    a.prepare("insert into devices (push_token, environment, created_at) values ('t','production',1)").run();
    a.close();
    const b = openDatabase(path);
    expect(b.prepare('select count(*) as n from devices').get()).toEqual({ n: 1 });
    b.close();
  });
});
