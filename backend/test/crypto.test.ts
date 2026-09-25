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
});
