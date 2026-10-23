import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { SecretBox } from '../src/crypto.js';
import { openDatabase } from '../src/db.js';
import { Repository } from '../src/repository.js';
import { AccountWatcher, authBackoffDelay, WatcherManager } from '../src/watcher.js';

type Outcome = 'auth' | 'net' | 'ok';

/**
 * Gerçek IMAP sunucusu yerine betiklenebilir sahte istemci: her `connect()`
 * `FakeImap.script`'ten sıradaki sonucu tüketir (betik biterse hep `ok`).
 */
const fake = vi.hoisted(() => ({
  script: [] as Outcome[],
  connects: 0,
  /** `fetch`in döndüreceği iletiler (`uid` ≥ istenen aralık başı olanlar). */
  messages: [] as any[],
  instances: [] as any[],
}));

vi.mock('imapflow', () => {
  class FakeImap {
    mailbox: unknown = false;
    private handlers = new Map<string, ((...args: any[]) => void)[]>();

    constructor() {
      fake.instances.push(this);
    }

    on(event: string, cb: (...args: any[]) => void) {
      const list = this.handlers.get(event) ?? [];
      list.push(cb);
      this.handlers.set(event, list);
      return this;
    }

    emit(event: string, ...args: unknown[]) {
      for (const cb of this.handlers.get(event) ?? []) cb(...args);
    }

    async connect() {
      fake.connects++;
      const outcome = fake.script.shift() ?? 'ok';
      if (outcome === 'auth') {
        throw Object.assign(new Error('Invalid credentials'), { authenticationFailed: true });
      }
      if (outcome === 'net') throw new Error('ECONNREFUSED');
    }

    async mailboxOpen() {
      this.mailbox = { uidValidity: 1n, uidNext: 11 };
    }

    async status() {
      return { unseen: 0 };
    }

    async *fetch(range: string) {
      const from = Number(range.split(':')[0]);
      for (const m of fake.messages) if (m.uid >= from) yield m;
    }

    async logout() {
      this.emit('close');
    }

    close() {
      this.emit('close');
    }
  }
  return { ImapFlow: FakeImap };
});

const TOKEN = 'ab'.repeat(32);

function setup() {
  const db = openDatabase(':memory:');
  const repo = new Repository(db, new SecretBox('c'.repeat(64)));
  const upsert = (clientAccountId: number, username = `u${clientAccountId}@example.com`) =>
    repo.upsertAccount({
      installId: 'a'.repeat(32),
      pushToken: TOKEN,
      platform: 'ios',
      environment: 'development',
      clientAccountId,
      host: 'imap.example.com',
      port: 993,
      secure: true,
      username,
      password: 'pw',
    });
  const notifier = { notify: vi.fn(async () => {}) } as any;
  return { repo, upsert, notifier };
}

const flush = () => new Promise((r) => setTimeout(r, 0));

const message = (uid: number) => ({
  uid,
  flags: new Set<string>(),
  envelope: { subject: 'Konu', from: [{ name: 'Ali', address: 'ali@x.com' }] },
});

describe('authBackoffDelay', () => {
  it('5 → 15 → 30 → 60 dk, sonra 60 dk sabit (sapma %10)', () => {
    const mid = () => 0.5;
    expect(authBackoffDelay(1, mid)).toBe(5 * 60_000);
    expect(authBackoffDelay(2, mid)).toBe(15 * 60_000);
    expect(authBackoffDelay(3, mid)).toBe(30 * 60_000);
    expect(authBackoffDelay(4, mid)).toBe(60 * 60_000);
    expect(authBackoffDelay(50, mid)).toBe(60 * 60_000);
    expect(authBackoffDelay(0, mid)).toBe(5 * 60_000);
  });
});

describe('AccountWatcher dayanıklılığı', () => {
  beforeEach(() => {
    fake.script = [];
    fake.connects = 0;
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it('kimlik hatası izlemeyi ÖLDÜRMEZ: durumu auth_failed olur, yeniden denenip watching olur', async () => {
    const s = setup();
    const account = s.upsert(1);
    fake.script = ['auth', 'auth', 'ok'];
    const onAuthFailed = vi.fn();
    const watcher = new AccountWatcher(account, {
      repo: s.repo,
      notifier: s.notifier,
      onAuthFailed,
      authBackoff: () => 1, // testte beklemeyi 1 ms'ye indir
    });

    expect(watcher.status).toBe('connecting');
    watcher.start();

    await vi.waitFor(() => expect(watcher.status).toBe('watching'));
    expect(fake.connects).toBe(3); // 2 ret + 1 başarı: vazgeçmedi
    expect(onAuthFailed).toHaveBeenCalledTimes(2);

    await watcher.stop();
  });

  it('kimlik reddedilirken durum auth_failed raporlanır', async () => {
    const s = setup();
    const account = s.upsert(1);
    fake.script = ['auth'];
    const watcher = new AccountWatcher(account, {
      repo: s.repo,
      notifier: s.notifier,
      authBackoff: () => 60_000, // ikinci denemeden önce bekletir
    });
    watcher.start();

    await vi.waitFor(() => expect(watcher.status).toBe('auth_failed'));
    expect(fake.connects).toBe(1);

    await watcher.stop(); // uzun bekleme stop() ile kesilir
  });

  it('art arda bağlantı hataları unreachable, başarı yeniden watching yapar', async () => {
    vi.useFakeTimers();
    const s = setup();
    const account = s.upsert(1);
    fake.script = ['net', 'net', 'net', 'ok'];
    const watcher = new AccountWatcher(account, { repo: s.repo, notifier: s.notifier });
    watcher.start();

    // Her başarısızlıktan sonra geri çekilme (≤ ~5 sn) ilerletilir.
    await vi.advanceTimersByTimeAsync(0);
    expect(watcher.status).toBe('connecting');
    await vi.advanceTimersByTimeAsync(2_000);
    await vi.advanceTimersByTimeAsync(4_000);
    expect(watcher.status).toBe('unreachable');
    await vi.advanceTimersByTimeAsync(10_000);
    expect(watcher.status).toBe('watching');

    vi.useRealTimers();
    await watcher.stop();
  });
});

describe('bildirim teslim garantisi', () => {
  beforeEach(() => {
    fake.script = [];
    fake.connects = 0;
    fake.messages = [];
    fake.instances = [];
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it('push iletilemezse imleç İLERLEMEZ, sonra yeniden denenir ve bildirim kaybolmaz', async () => {
    vi.useFakeTimers();
    const s = setup();
    const account = s.upsert(1);
    const notify = vi
      .fn()
      .mockResolvedValueOnce('failed')
      .mockResolvedValue('sent');
    const watcher = new AccountWatcher(account, {
      repo: s.repo,
      notifier: { notify } as any,
    });
    watcher.start();
    await vi.advanceTimersByTimeAsync(0);
    expect(watcher.status).toBe('watching');
    expect(s.repo.getAccount(account.id)!.last_uid).toBe(10); // açılışta uidNext - 1

    fake.messages = [message(11)];
    fake.instances.at(-1).emit('exists', { prevCount: 0, count: 1 });
    await vi.advanceTimersByTimeAsync(0);

    expect(notify).toHaveBeenCalledTimes(1);
    expect(s.repo.getAccount(account.id)!.last_uid).toBe(10); // başarısız: ilerlemedi

    await vi.advanceTimersByTimeAsync(30_000);
    expect(notify).toHaveBeenCalledTimes(2);
    expect(notify.mock.calls[1]![1]).toEqual([expect.objectContaining({ uid: 11 })]);
    expect(s.repo.getAccount(account.id)!.last_uid).toBe(11);

    vi.useRealTimers();
    await watcher.stop();
  });

  it('izleyici yenilenirken (yeniden kayıt) süren tarama ile yenisinin ilk taraması AYNI iletiyi iki kez bildirmez', async () => {
    const s = setup();
    const account = s.upsert(1);
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const notify = vi.fn(async () => {
      await gate; // push sağlayıcısı yavaş: tarama bu sırada sürüyor
      return 'sent' as const;
    });
    const manager = new WatcherManager({ repo: s.repo, notifier: { notify } as any });
    manager.onAccountUpserted(account);
    await vi.waitFor(() => expect(manager.statusOf(account.id)).toBe('watching'));

    fake.messages = [message(11)];
    fake.instances.at(-1).emit('exists', { prevCount: 0, count: 1 });
    await vi.waitFor(() => expect(notify).toHaveBeenCalledTimes(1));

    // İstemci hesabı yeniden kaydetti: eski izleyici durur, yenisi başlar.
    manager.onAccountUpserted(s.repo.getAccount(account.id)!);
    await vi.waitFor(() => expect(fake.connects).toBe(2));
    await new Promise((r) => setTimeout(r, 20));
    expect(notify).toHaveBeenCalledTimes(1); // yeni tarama kilidi bekliyor

    release();
    await vi.waitFor(() => expect(s.repo.getAccount(account.id)!.last_uid).toBe(11));
    await new Promise((r) => setTimeout(r, 30));
    expect(notify).toHaveBeenCalledTimes(1); // ikinci tarama imleci görüp yeni ileti bulmadı

    await manager.stopAll();
  });

  it('push kabul edilince (ya da kalıcı reddedilince) imleç ilerler, tekrar bildirilmez', async () => {
    const s = setup();
    const account = s.upsert(1);
    const notify = vi.fn().mockResolvedValue('dropped');
    const watcher = new AccountWatcher(account, { repo: s.repo, notifier: { notify } as any });
    watcher.start();
    await vi.waitFor(() => expect(watcher.status).toBe('watching'));

    fake.messages = [message(11), message(12)];
    fake.instances.at(-1).emit('exists', { prevCount: 0, count: 2 });
    await vi.waitFor(() => expect(notify).toHaveBeenCalledTimes(1));
    await vi.waitFor(() => expect(s.repo.getAccount(account.id)!.last_uid).toBe(12));

    // Aynı olay yeniden gelse de yeni ileti yok: ikinci bildirim yok.
    fake.instances.at(-1).emit('exists', { prevCount: 2, count: 2 });
    await new Promise((r) => setTimeout(r, 20));
    expect(notify).toHaveBeenCalledTimes(1);

    await watcher.stop();
  });
});

describe('WatcherManager çoklu hesap', () => {
  beforeEach(() => {
    fake.script = [];
    fake.connects = 0;
    fake.messages = [];
    fake.instances = [];
  });

  it('bir hesabın kimlik hatası diğer hesapların izlemesini etkilemez; durumlar ayrı raporlanır', async () => {
    const s = setup();
    const a = s.upsert(1);
    const b = s.upsert(2);
    const c = s.upsert(3);
    // Bağlantı sırası: a → ok, b → auth, c → ok
    fake.script = ['ok', 'auth', 'ok'];
    const manager = new WatcherManager(
      { repo: s.repo, notifier: s.notifier, authBackoff: () => 60_000 },
      { globalMs: 1, perHostMs: 1 },
    );

    manager.onAccountUpserted(a);
    await flush();
    manager.onAccountUpserted(b);
    await flush();
    manager.onAccountUpserted(c);

    await vi.waitFor(() => {
      expect(manager.statusOf(a.id)).toBe('watching');
      expect(manager.statusOf(b.id)).toBe('auth_failed');
      expect(manager.statusOf(c.id)).toBe('watching');
    });

    // Reddedilen hesap yeniden kaydedilince (taze şifre) izleyici yenilenir.
    fake.script = ['ok'];
    manager.onAccountUpserted(s.repo.getAccount(b.id)!);
    await vi.waitFor(() => expect(manager.statusOf(b.id)).toBe('watching'));
    expect(manager.statusOf(a.id)).toBe('watching');

    await manager.stopAll();
  });

  it('izleyicisi olmayan hesap için statusOf undefined döner', () => {
    const s = setup();
    const manager = new WatcherManager({ repo: s.repo, notifier: s.notifier });
    expect(manager.statusOf(999)).toBeUndefined();
  });

  it('silinen hesabın izleyicisi durur, diğerleri sürer', async () => {
    const s = setup();
    const a = s.upsert(1);
    const b = s.upsert(2);
    const manager = new WatcherManager({ repo: s.repo, notifier: s.notifier });
    manager.onAccountUpserted(a);
    manager.onAccountUpserted(b);
    await vi.waitFor(() => {
      expect(manager.statusOf(a.id)).toBe('watching');
      expect(manager.statusOf(b.id)).toBe('watching');
    });

    manager.onAccountsRemoved([a.id]);
    expect(manager.statusOf(a.id)).toBeUndefined();
    expect(manager.statusOf(b.id)).toBe('watching');

    await manager.stopAll();
  });
});
