import { ImapFlow, type FetchMessageObject } from 'imapflow';
import type { AccountHooks } from './app.js';
import type { AccountRow } from './db.js';
import type { NewMessage, Notifier } from './notifier.js';
import type { Repository } from './repository.js';

const MAX_FIELD = 160;

/** Yeniden bağlanma bekleme süresi: 1 sn'den başlar, 60 sn'ye kadar katlanır. */
export function backoffDelay(attempt: number, random: () => number = Math.random): number {
  const base = Math.min(60_000, 1000 * 2 ** Math.min(attempt, 6));
  // Tüm hesapların aynı anda bağlanmaya çalışmaması için %20'ye kadar sapma.
  return Math.round(base * (0.8 + random() * 0.4));
}

const clip = (text: string) =>
  text.length > MAX_FIELD ? `${text.slice(0, MAX_FIELD - 1)}…` : text;

/** IMAP zarfını bildirim için sadeleştirir; okunmuşsa null. */
export function describeMessage(m: FetchMessageObject): NewMessage | null {
  if (m.flags?.has('\\Seen')) return null;
  const from = m.envelope?.from?.[0];
  const fromName = (from?.name || from?.address || 'Yeni ileti').trim();
  const subject = (m.envelope?.subject ?? '').trim() || '(Konu yok)';
  return { uid: m.uid, fromName: clip(fromName), subject: clip(subject) };
}

export interface WatcherDeps {
  repo: Repository;
  notifier: Notifier;
  onAuthFailed?: (accountId: number) => void;
  log?: (message: string) => void;
}

/**
 * Tek bir hesabın INBOX'ını IMAP IDLE ile izler. Sunucu yeni ileti bildirir
 * bildirmez zarf (gönderen + konu) çekilir ve push gönderilir; gövde
 * indirilmez, böylece gecikme tek gidiş-dönüşle sınırlı kalır.
 */
export class AccountWatcher {
  private stopped = false;
  private client: ImapFlow | null = null;
  private wake: (() => void) | null = null;
  private draining = false;
  private drainAgain = false;
  private unreadTimer: NodeJS.Timeout | null = null;
  private readonly log: (message: string) => void;

  constructor(
    private readonly account: AccountRow,
    private readonly deps: WatcherDeps,
  ) {
    this.log = deps.log ?? (() => {});
  }

  start(): void {
    void this.run();
  }

  async stop(): Promise<void> {
    this.stopped = true;
    if (this.unreadTimer) clearTimeout(this.unreadTimer);
    this.wake?.();
    const client = this.client;
    this.client = null;
    if (client) {
      try {
        await client.logout();
      } catch {
        client.close();
      }
    }
  }

  private async run(): Promise<void> {
    let attempt = 0;
    while (!this.stopped) {
      try {
        await this.session(() => {
          attempt = 0;
        });
      } catch (e) {
        const err = e as Error & { authenticationFailed?: boolean };
        if (err.authenticationFailed) {
          this.log(`hesap ${this.account.id}: kimlik doğrulama başarısız, izleme durdu`);
          this.deps.onAuthFailed?.(this.account.id);
          return;
        }
        this.log(`hesap ${this.account.id}: ${err.message}`);
      }
      if (this.stopped) return;
      await this.sleep(backoffDelay(attempt++));
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => {
      const timer = setTimeout(resolve, ms);
      this.wake = () => {
        clearTimeout(timer);
        resolve();
      };
    });
  }

  /** Bağlanır, INBOX'ı açık tutup IDLE'da bekler; bağlantı kapanınca döner. */
  private async session(onReady: () => void): Promise<void> {
    const { repo } = this.deps;
    const client = new ImapFlow({
      host: this.account.imap_host,
      port: this.account.imap_port,
      secure: this.account.imap_secure === 1,
      auth: { user: this.account.username, pass: repo.decryptPassword(this.account) },
      logger: false,
      // Yarı ölü bağlantıları (NAT zaman aşımı) erken yakalamak için IDLE
      // periyodik olarak yenilenir.
      maxIdleTime: 5 * 60 * 1000,
      // Bir komuttan sonra IDLE'a dönmeden önce beklenen süre (varsayılan 15 sn).
      // IDLE dışındayken sunucu yeni iletiyi bildirmez; bu aralık gecikme olur.
      autoIdleDelay: 1000,
    });
    this.client = client;
    const closed = new Promise<void>((resolve) => client.on('close', () => resolve()));
    // 'error' dinleyicisi olmazsa süreç düşer; asıl hata connect/lock'tan gelir.
    client.on('error', (e: Error) => this.log(`hesap ${this.account.id}: ${e.message}`));

    await client.connect();
    this.log(`hesap ${this.account.id}: bağlandı`);
    // Bilerek `getMailboxLock` DEĞİL `mailboxOpen`: imapflow kilit tutulurken
    // IDLE'a geçmez, yalnızca NOOP ile yoklar (yeni ileti ~5 dk geç gelir).
    // Kilitsiz açılan bağlantı boştayken otomatik IDLE'a girer.
    await client.mailboxOpen('INBOX');
    try {
      await this.initialize(client);
      onReady();
      this.log(`hesap ${this.account.id}: INBOX açık, IDLE bekleniyor`);
      client.on('exists', (e: { prevCount: number; count: number }) => {
        this.log(`hesap ${this.account.id}: exists ${e.prevCount} -> ${e.count}`);
        void this.drain(client);
      });
      client.on('flags', () => this.scheduleUnreadRefresh(client));
      // Bağlantı kesintisinde gelen iletileri kaçırmamak için hemen tara.
      await this.drain(client);
      await closed;
    } finally {
      this.client = null;
      this.log(`hesap ${this.account.id}: bağlantı kapandı`);
    }
  }

  private mailbox(client: ImapFlow) {
    const mb = client.mailbox;
    if (!mb || typeof mb === 'boolean') throw new Error('INBOX açılamadı');
    return mb;
  }

  private async initialize(client: ImapFlow): Promise<void> {
    const { repo } = this.deps;
    const mb = this.mailbox(client);
    const uidValidity = Number(mb.uidValidity);
    const highest = mb.uidNext - 1;
    const stored = repo.getAccount(this.account.id);
    // İlk kurulum ya da UIDVALIDITY değişimi: eski iletiler için bildirim atma.
    if (!stored || stored.last_uid === null || stored.uid_validity !== uidValidity) {
      repo.setCursor(this.account.id, highest, uidValidity);
    }
    await this.refreshUnread(client);
  }

  private async refreshUnread(client: ImapFlow): Promise<void> {
    try {
      const status = await client.status('INBOX', { unseen: true });
      this.deps.repo.setUnread(this.account.id, status.unseen ?? 0);
    } catch (e) {
      this.log(`hesap ${this.account.id}: okunmamış sayısı alınamadı: ${(e as Error).message}`);
    }
  }

  private scheduleUnreadRefresh(client: ImapFlow): void {
    if (this.unreadTimer) clearTimeout(this.unreadTimer);
    this.unreadTimer = setTimeout(() => void this.refreshUnread(client), 1000);
  }

  /** Son bilinen UID'den sonra gelen iletileri bulup bildirir; eşzamanlı çağrılar birleşir. */
  private async drain(client: ImapFlow): Promise<void> {
    if (this.draining) {
      this.drainAgain = true;
      return;
    }
    this.draining = true;
    try {
      do {
        this.drainAgain = false;
        await this.drainOnce(client);
      } while (this.drainAgain && !this.stopped);
    } catch (e) {
      this.log(`hesap ${this.account.id}: tarama hatası: ${(e as Error).message}`);
    } finally {
      this.draining = false;
    }
  }

  private async drainOnce(client: ImapFlow): Promise<void> {
    const { repo, notifier } = this.deps;
    const stored = repo.getAccount(this.account.id);
    if (!stored || stored.last_uid === null) return;
    const uidValidity = Number(this.mailbox(client).uidValidity);

    const fresh: FetchMessageObject[] = [];
    // `N:*` her zaman en az son iletiyi döndürür; eskileri ayıkla.
    for await (const m of client.fetch(
      `${stored.last_uid + 1}:*`,
      { uid: true, flags: true, envelope: true },
      { uid: true },
    )) {
      if (m.uid > stored.last_uid) fresh.push(m);
    }
    if (fresh.length === 0) return;

    fresh.sort((a, b) => a.uid - b.uid);
    const unseen = fresh.map(describeMessage).filter((m): m is NewMessage => m !== null);
    repo.setCursor(this.account.id, fresh[fresh.length - 1]!.uid, uidValidity);
    if (unseen.length === 0) return;

    // Push'u beklemeden gidecek sayıyı önbellekten tahmin et; kesin değer
    // hemen ardından sunucudan alınıp düzeltilir.
    repo.setUnread(this.account.id, stored.unread + unseen.length);
    const updated = repo.getAccount(this.account.id)!;
    await notifier.notify(updated, unseen);
    await this.refreshUnread(client);
  }
}

/** Hesap kaydı/silinmesi olaylarında izleyicileri başlatıp durdurur. */
export class WatcherManager implements AccountHooks {
  private readonly watchers = new Map<number, AccountWatcher>();

  constructor(private readonly deps: WatcherDeps) {}

  startAll(): void {
    for (const account of this.deps.repo.listAccounts()) this.begin(account);
  }

  onAccountUpserted(account: AccountRow): void {
    this.begin(account);
  }

  onAccountsRemoved(accountIds: number[]): void {
    for (const id of accountIds) this.end(id);
  }

  async stopAll(): Promise<void> {
    const all = [...this.watchers.values()];
    this.watchers.clear();
    await Promise.all(all.map((w) => w.stop()));
  }

  private begin(account: AccountRow): void {
    this.end(account.id);
    this.deps.log?.(`hesap ${account.id}: izleme başlatıldı`);
    const watcher = new AccountWatcher(account, {
      ...this.deps,
      onAuthFailed: (id) => {
        this.watchers.delete(id);
        this.deps.onAuthFailed?.(id);
      },
    });
    this.watchers.set(account.id, watcher);
    watcher.start();
  }

  private end(id: number): void {
    const watcher = this.watchers.get(id);
    if (!watcher) return;
    this.watchers.delete(id);
    void watcher.stop();
  }
}
