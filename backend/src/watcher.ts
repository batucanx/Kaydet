import { ImapFlow, type FetchMessageObject } from 'imapflow';
import type { AccountHooks } from './app.js';
import type { AccountRow } from './db.js';
import type { NewMessage, Notifier } from './notifier.js';
import type { Repository } from './repository.js';

const MAX_FIELD = 160;

/**
 * Bir hesabın sunucudaki izleme durumu (bkz. `GET /v1/accounts`).
 *
 * - `connecting`: bağlanıyor ya da kademeli başlatma sırasında bekliyor.
 * - `watching`: INBOX açık, IDLE'da bekliyor — yeni ileti anında bildirilir.
 * - `auth_failed`: IMAP sunucusu kimlik bilgisini reddetti (şifre değişmiş ya da
 *   sağlayıcı bu sunucunun IP'sini engelliyor). İzleme DURMAZ, seyrek aralıkla
 *   yeniden denenir; istemci taze şifreyle yeniden kaydederek hemen deneyebilir.
 * - `unreachable`: IMAP sunucusuna art arda bağlanılamadı (ağ, TLS, yanlış sunucu).
 */
export type WatchStatus = 'connecting' | 'watching' | 'auth_failed' | 'unreachable';

/** Bağlantı hatası bu kadar art arda tekrarlanınca hesap `unreachable` sayılır. */
const UNREACHABLE_AFTER = 3;

/** Yeniden bağlanma bekleme süresi: 1 sn'den başlar, 60 sn'ye kadar katlanır. */
export function backoffDelay(attempt: number, random: () => number = Math.random): number {
  const base = Math.min(60_000, 1000 * 2 ** Math.min(attempt, 6));
  // Tüm hesapların aynı anda bağlanmaya çalışmaması için %20'ye kadar sapma.
  return Math.round(base * (0.8 + random() * 0.4));
}

/**
 * Kimlik hatasından sonra bekleme: 5 → 15 → 30 → 60 dk (üst sınır). Sağlayıcılar
 * yanlış parolayla sık denemeyi hesabı kilitlemekle cezalandırır; bu yüzden
 * seyrek, ama ASLA vazgeçmeden denenir (kalıcı bir durma, istemci hiçbir şey
 * fark etmeden hesabın bildirimsiz kalması demekti).
 */
export function authBackoffDelay(failures: number, random: () => number = Math.random): number {
  const steps = [5, 15, 30, 60];
  const minutes = steps[Math.min(Math.max(failures, 1), steps.length) - 1]!;
  return Math.round(minutes * 60_000 * (0.9 + random() * 0.2));
}

const clip = (text: string) =>
  text.length > MAX_FIELD ? `${text.slice(0, MAX_FIELD - 1)}…` : text;

/** IMAP zarfını bildirim için sadeleştirir; okunmuşsa null. */
export function describeMessage(m: FetchMessageObject): NewMessage | null {
  if (m.flags?.has('\\Seen')) return null;
  const from = m.envelope?.from?.[0];
  const fromName = (from?.name || from?.address || 'Yeni ileti').trim();
  const subject = (m.envelope?.subject ?? '').trim() || '(Konu yok)';
  // Bozuk `Date` başlığı geçersiz bir Date üretir; `toISOString()` RangeError
  // fırlatıp bildirimi düşürmesin — tarih yoksa uygulama kendi değerini kullanır.
  const sentAt = m.envelope?.date ? new Date(m.envelope.date) : null;
  const date = sentAt && !Number.isNaN(sentAt.getTime()) ? sentAt : null;
  const messageId = m.envelope?.messageId?.trim();
  return {
    uid: m.uid,
    fromName: clip(fromName),
    subject: clip(subject),
    ...(date ? { date: date.toISOString() } : {}),
    ...(messageId ? { messageId } : {}),
  };
}

/**
 * Aynı anahtar için işleri sırayla çalıştırır (promise zinciri). Bir hesabın
 * izleyicisi yenilenirken (`PUT /v1/accounts`) eski izleyicinin süren taraması
 * ile yenisinin ilk taraması aynı imleci okuyup aynı iletileri iki kez
 * bildirmesin diye hesap başına tek tarama koşar.
 */
export class KeyedMutex {
  private readonly tails = new Map<number, Promise<void>>();

  async run<T>(key: number, task: () => Promise<T>): Promise<T> {
    const previous = this.tails.get(key) ?? Promise.resolve();
    let release!: () => void;
    const mine = new Promise<void>((resolve) => {
      release = resolve;
    });
    const tail = previous.then(() => mine);
    this.tails.set(key, tail);
    await previous;
    try {
      return await task();
    } finally {
      release();
      if (this.tails.get(key) === tail) this.tails.delete(key);
    }
  }
}

export interface WatcherDeps {
  repo: Repository;
  notifier: Notifier;
  /** Kimlik reddedildiğinde (her denemede) çağrılır; izleme yine de sürer. */
  onAuthFailed?: (accountId: number) => void;
  log?: (message: string) => void;
  /** Testler için; varsayılan gerçek zamanlayıcı bekleme. */
  authBackoff?: (failures: number) => number;
  /** Hesap başına tarama kilidi; `WatcherManager` tüm izleyicilerine ortak verir. */
  drainLock?: KeyedMutex;
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
  private retryTimer: NodeJS.Timeout | null = null;
  private retryAttempt = 0;
  private readonly log: (message: string) => void;
  private readonly drainLock: KeyedMutex;
  private current: WatchStatus = 'connecting';

  constructor(
    private readonly account: AccountRow,
    private readonly deps: WatcherDeps,
  ) {
    this.log = deps.log ?? (() => {});
    this.drainLock = deps.drainLock ?? new KeyedMutex();
  }

  /** Şu anki izleme durumu (bkz. `WatchStatus`). */
  get status(): WatchStatus {
    return this.current;
  }

  start(): void {
    void this.run();
  }

  async stop(): Promise<void> {
    this.stopped = true;
    if (this.unreadTimer) clearTimeout(this.unreadTimer);
    if (this.retryTimer) clearTimeout(this.retryTimer);
    this.retryTimer = null;
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
    let authFailures = 0;
    let connectFailures = 0;
    const authBackoff = this.deps.authBackoff ?? authBackoffDelay;
    while (!this.stopped) {
      let wait: number | null = null;
      try {
        await this.session(() => {
          attempt = 0;
          authFailures = 0;
          connectFailures = 0;
          this.current = 'watching';
        });
        // Oturum sağlıklı kurulup sonra koptu: yeniden bağlanırken `connecting`.
        if (!this.stopped) this.current = 'connecting';
      } catch (e) {
        const err = e as Error & { authenticationFailed?: boolean };
        if (err.authenticationFailed) {
          // ESKİDEN burada `return` edilirdi: tek bir geçici kimlik hatası
          // (sağlayıcının hız sınırı, eşzamanlı bağlantı üst sınırı) hesabı
          // sunucu yeniden başlayana dek sessizce izlenmez bırakırdı. Artık
          // vazgeçilmez; yalnızca seyrek denenir.
          authFailures++;
          this.current = 'auth_failed';
          wait = authBackoff(authFailures);
          this.log(
            `hesap ${this.account.id} (${this.account.username}): kimlik doğrulama başarısız (${err.message}), ${Math.round(wait / 60_000)} dk sonra yeniden denenecek`,
          );
          this.deps.onAuthFailed?.(this.account.id);
        } else {
          connectFailures++;
          this.current = connectFailures >= UNREACHABLE_AFTER ? 'unreachable' : 'connecting';
          this.log(`hesap ${this.account.id} (${this.account.username}): ${err.message}`);
        }
      }
      if (this.stopped) return;
      await this.sleep(wait ?? backoffDelay(attempt++));
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
      // Bekleyen yeniden deneme bu (kapanan) bağlantıya bağlıydı; yeni oturum
      // açılışta zaten tüm eksik iletileri tarar.
      if (this.retryTimer) clearTimeout(this.retryTimer);
      this.retryTimer = null;
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
        await this.drainLock.run(this.account.id, () => this.drainOnce(client));
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
    const newest = fresh[fresh.length - 1]!.uid;
    if (unseen.length === 0) {
      repo.setCursor(this.account.id, newest, uidValidity);
      return;
    }

    // Push'u beklemeden gidecek sayıyı önbellekten tahmin et; kesin değer
    // hemen ardından sunucudan alınıp düzeltilir.
    repo.setUnread(this.account.id, stored.unread + unseen.length);
    const updated = repo.getAccount(this.account.id)!;
    const result = await notifier.notify(updated, unseen, uidValidity);
    if (result === 'failed') {
      // İmleç ilerletilmez: aynı iletiler bir sonraki taramada yeniden bildirilir.
      // (Eskiden imleç push'tan ÖNCE ilerletilirdi; sağlayıcı kesintisi ya da ağ
      // hatası bildirimi sessizce ve kalıcı olarak kaybettirirdi.)
      this.scheduleNotifyRetry(client);
    } else {
      this.retryAttempt = 0;
      repo.setCursor(this.account.id, newest, uidValidity);
    }
    await this.refreshUnread(client);
  }

  /** Başarısız push için 30 sn → 2 dk → 5 dk → 15 dk (sabit) aralıkla yeniden tarar. */
  private scheduleNotifyRetry(client: ImapFlow): void {
    if (this.stopped || this.retryTimer) return;
    const steps = [30_000, 120_000, 300_000, 900_000];
    const delay = steps[Math.min(this.retryAttempt++, steps.length - 1)]!;
    this.log(
      `hesap ${this.account.id}: push iletilemedi, ${Math.round(delay / 1000)} sn sonra yeniden denenecek`,
    );
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null;
      if (!this.stopped) void this.drain(client);
    }, delay);
  }
}

export interface StaggerOptions {
  /** Art arda iki başlatma arasındaki en kısa süre (tüm hesaplar için). */
  globalMs: number;
  /** Aynı IMAP sunucusuna iki bağlantı arasındaki en kısa süre. */
  perHostMs: number;
}

/**
 * Sunucu yeniden başlayınca yüzlerce hesap aynı saniyede bağlanmasın: sağlayıcılar
 * (Yandex, ortak hosting) kısa sürede çok bağlantıyı hız sınırıyla ya da geçici
 * IP/hesap engeliyle karşılar. Varsayılan: toplamda saniyede ~10, aynı sunucuya
 * saniyede 2 bağlantı.
 */
export const DEFAULT_STAGGER: StaggerOptions = { globalMs: 100, perHostMs: 500 };

/**
 * Hesap başına başlatma gecikmelerini hesaplar (ms). Her sunucu kendi
 * `perHostMs` aralığını izler; bir sunucunun bekleyen hesapları diğer
 * sunucuları GECİKTİRMEZ. `globalMs` yalnızca iki başlatmanın aynı anda
 * olmasını önler (farklı sunucuların bağlantıları arasında en az bu kadar fark).
 */
export function staggerOffsets(
  hosts: string[],
  { globalMs, perHostMs }: StaggerOptions,
): number[] {
  const nextByHost = new Map<string, number>();
  const usedSlots = new Set<number>();
  return hosts.map((host) => {
    const key = host.toLowerCase();
    let slot = Math.ceil((nextByHost.get(key) ?? 0) / globalMs);
    while (usedSlots.has(slot)) slot++;
    usedSlots.add(slot);
    const at = slot * globalMs;
    nextByHost.set(key, at + perHostMs);
    return at;
  });
}

/** Hesap kaydı/silinmesi olaylarında izleyicileri başlatıp durdurur. */
export class WatcherManager implements AccountHooks {
  private readonly drainLock = new KeyedMutex();
  private readonly watchers = new Map<number, AccountWatcher>();
  /** Henüz başlamamış (kademeli sıradaki) hesapların zamanlayıcıları. */
  private readonly pending = new Map<number, NodeJS.Timeout>();

  constructor(
    private readonly deps: WatcherDeps,
    private readonly stagger: StaggerOptions = DEFAULT_STAGGER,
  ) {}

  /** Açılışta tüm hesapları KADEMELİ başlatır (bkz. `staggerOffsets`). */
  startAll(): void {
    const accounts = this.deps.repo.listAccounts();
    const offsets = staggerOffsets(
      accounts.map((a) => a.imap_host),
      this.stagger,
    );
    const last = offsets[offsets.length - 1] ?? 0;
    if (accounts.length > 1) {
      this.deps.log?.(
        `${accounts.length} hesap kademeli başlatılıyor (yaklaşık ${Math.ceil(last / 1000)} sn)`,
      );
    }
    accounts.forEach((account, i) => {
      const delay = offsets[i] ?? 0;
      if (delay === 0) {
        this.begin(account);
        return;
      }
      const timer = setTimeout(() => {
        this.pending.delete(account.id);
        // Beklerken silinmiş ya da güncellenmiş olabilir: güncel kaydı kullan.
        const current = this.deps.repo.getAccount(account.id);
        if (current) this.begin(current);
      }, delay);
      this.pending.set(account.id, timer);
    });
  }

  onAccountUpserted(account: AccountRow): void {
    this.begin(account);
  }

  onAccountsRemoved(accountIds: number[]): void {
    for (const id of accountIds) this.end(id);
  }

  /**
   * Hesabın şu anki izleme durumu. Kademeli başlatmada sırasını bekleyen
   * hesap `connecting` sayılır; hiç izleyicisi/zamanlayıcısı olmayan hesap
   * `undefined` döner (istemci bunu "izlenmiyor" diye yorumlar).
   */
  statusOf(accountId: number): WatchStatus | undefined {
    const watcher = this.watchers.get(accountId);
    if (watcher) return watcher.status;
    return this.pending.has(accountId) ? 'connecting' : undefined;
  }

  async stopAll(): Promise<void> {
    for (const timer of this.pending.values()) clearTimeout(timer);
    this.pending.clear();
    const all = [...this.watchers.values()];
    this.watchers.clear();
    await Promise.all(all.map((w) => w.stop()));
  }

  private begin(account: AccountRow): void {
    this.end(account.id);
    this.deps.log?.(`hesap ${account.id} (${account.username} @ ${account.imap_host}): izleme başlatıldı`);
    // Kimlik hatası izleyiciyi öldürmez (bkz. `AccountWatcher.run`): izleyici
    // haritada kalır ki durumu raporlanabilsin ve seyrek yeniden denensin.
    const watcher = new AccountWatcher(account, { ...this.deps, drainLock: this.drainLock });
    this.watchers.set(account.id, watcher);
    watcher.start();
  }

  private end(id: number): void {
    const timer = this.pending.get(id);
    if (timer) {
      clearTimeout(timer);
      this.pending.delete(id);
    }
    const watcher = this.watchers.get(id);
    if (!watcher) return;
    this.watchers.delete(id);
    void watcher.stop();
  }
}
