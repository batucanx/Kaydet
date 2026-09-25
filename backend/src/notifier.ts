import { buildMailPayload, type ApnsClient } from './apns.js';
import type { AccountRow } from './db.js';
import type { Repository } from './repository.js';

export interface NewMessage {
  uid: number;
  fromName: string;
  subject: string;
}

export interface NotifierOptions {
  /** Token geçersiz çıkınca cihazla birlikte silinen hesapların id'leri. */
  onDevicesRemoved?: (accountIds: number[]) => void;
  sleep?: (ms: number) => Promise<void>;
}

// Geçici APNs hatalarında hızlı, kısa yeniden denemeler: bildirim gecikmesin
// ama bir kesinti yüzünden de kaybolmasın.
const RETRY_DELAYS_MS = [500, 2000];

const realSleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export class Notifier {
  private readonly sleep: (ms: number) => Promise<void>;

  constructor(
    private readonly repo: Repository,
    private readonly apns: Pick<ApnsClient, 'send'>,
    private readonly opts: NotifierOptions = {},
  ) {
    this.sleep = opts.sleep ?? realSleep;
  }

  /**
   * Yeni okunmamış iletiler için tek bir push gönderir. Birden fazla ileti
   * varsa (ör. bağlantı koptuğu sürede gelenler) özet bildirim atılır.
   * Rozet, hesabın `unread` değeri güncellendikten SONRA çağrılmalıdır.
   */
  async notify(account: AccountRow, messages: NewMessage[]): Promise<void> {
    const latest = messages[messages.length - 1];
    if (!latest) return;
    const device = this.repo.getDevice(account.device_id);
    if (!device) return;

    const badge = this.repo.deviceUnreadTotal(device.id);
    const latestLine = `${latest.fromName}: ${latest.subject}`;
    const payload =
      messages.length === 1
        ? buildMailPayload({
            title: latest.fromName,
            body: latest.subject,
            badge,
            threadId: `account-${account.client_account_id}`,
            data: { accountId: account.client_account_id, uid: latest.uid },
          })
        : buildMailPayload({
            title: `${messages.length} yeni ileti`,
            body: latestLine,
            badge,
            threadId: `account-${account.client_account_id}`,
            data: { accountId: account.client_account_id, uid: latest.uid },
          });

    for (let attempt = 0; ; attempt++) {
      const result = await this.apns.send(device.apns_token, device.environment, payload);
      if (result.status === 'sent') return;
      if (result.status === 'invalid_token') {
        const ids = this.repo.deleteDevice(device.apns_token);
        if (ids.length > 0) this.opts.onDevicesRemoved?.(ids);
        return;
      }
      const delay = RETRY_DELAYS_MS[attempt];
      if (!result.retryable || delay === undefined) return;
      await this.sleep(delay);
    }
  }
}
