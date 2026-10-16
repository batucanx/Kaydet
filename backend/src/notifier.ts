import { buildMailPayload, type ApnsClient } from './apns.js';
import type { FcmClient } from './fcm.js';
import type { AccountRow, ApnsEnvironment, DeviceRow } from './db.js';
import type { Repository } from './repository.js';

export interface NewMessage {
  uid: number;
  fromName: string;
  subject: string;
  /** İletinin tarihi (ISO 8601); zarfta yoksa belirtilmez. */
  date?: string;
  /**
   * RFC 5322 `Message-ID` başlığı (zarftan); yoksa belirtilmez. UID klasöre
   * özgüdür ve UIDVALIDITY değişince anlamını yitirir; bu kimlik, ileti başka
   * klasöre taşınsa da istemcinin onu bulabilmesini sağlar.
   */
  messageId?: string;
}

/** Push yükündeki en çok ileti sayısı; APNs yük sınırı 4 KB. */
const MAX_PAYLOAD_ITEMS = 8;
const MAX_ITEM_FIELD = 80;

const clipItem = (text: string) =>
  text.length > MAX_ITEM_FIELD ? `${text.slice(0, MAX_ITEM_FIELD - 1)}…` : text;

/**
 * İstemcideki Notification Service Extension'ın okuduğu kompakt ileti listesi
 * (u: uid, f: gönderen, s: konu, d: tarih). Uygulama kapalıyken bile liste
 * bu kayıtlardan hemen doldurulur (bkz. ios/NotificationService).
 */
function payloadItems(messages: NewMessage[]) {
  return messages.slice(-MAX_PAYLOAD_ITEMS).map((m) => ({
    u: m.uid,
    f: clipItem(m.fromName),
    s: clipItem(m.subject),
    ...(m.date ? { d: m.date } : {}),
  }));
}

/** Push yükündeki en uzun `messageId`; 4 KB'lık APNs sınırını korur. */
const MAX_MESSAGE_ID = 200;

/**
 * Bildirime dokunulunca istemcinin ilgili iletiyi KESİN bulabilmesi için
 * gereken hedef bilgisi (bkz. lib/app/notification_intent.dart).
 *
 * `folder` her zaman `INBOX`'tır: izleyici yalnızca Gelen Kutusu'nu dinler.
 */
function targetData(
  account: AccountRow,
  latest: NewMessage,
  uidValidity: number | undefined,
) {
  return {
    type: 'new_mail',
    accountId: account.client_account_id,
    folder: 'INBOX',
    uid: latest.uid,
    ...(uidValidity !== undefined ? { uidValidity } : {}),
    ...(latest.messageId && latest.messageId.length <= MAX_MESSAGE_ID
      ? { messageId: latest.messageId }
      : {}),
  };
}

export interface NotifierOptions {
  /** Android cihazlar için; yoksa Android kayıtlarına push gönderilmez. */
  fcm?: Pick<FcmClient, 'send'>;
  /** Token geçersiz çıkınca cihazla birlikte silinen hesapların id'leri. */
  onDevicesRemoved?: (accountIds: number[]) => void;
  sleep?: (ms: number) => Promise<void>;
  /** Sonuç günlüğü; cihaz token'ı ya da içerik ASLA yazılmaz. */
  log?: (message: string) => void;
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
  async notify(
    account: AccountRow,
    messages: NewMessage[],
    uidValidity?: number,
  ): Promise<void> {
    const latest = messages[messages.length - 1];
    if (!latest) return;
    const device = this.repo.getDevice(account.device_id);
    if (!device) return;
    if (device.platform === 'android') {
      await this.notifyAndroid(account, device, messages, uidValidity);
      return;
    }

    const badge = this.repo.deviceUnreadTotal(device.id);
    const latestLine = `${latest.fromName}: ${latest.subject}`;
    const payload =
      messages.length === 1
        ? buildMailPayload({
            title: latest.fromName,
            body: latest.subject,
            badge,
            threadId: `account-${account.client_account_id}`,
            data: {
              ...targetData(account, latest, uidValidity),
              items: payloadItems(messages),
            },
          })
        : buildMailPayload({
            title: `${messages.length} yeni ileti`,
            body: latestLine,
            badge,
            threadId: `account-${account.client_account_id}`,
            data: {
              ...targetData(account, latest, uidValidity),
              items: payloadItems(messages),
            },
          });

    for (let attempt = 0; ; attempt++) {
      let currentEnv = device.environment;
      let result = await this.apns.send(device.push_token, currentEnv, payload);
      if (result.status === 'sent') {
        this.opts.log?.(`hesap ${account.id}: push gönderildi (${currentEnv})`);
        return;
      }
      if (result.status === 'invalid_token') {
        // Ortam uyuşmazlığında (geliştirici sertifikasıyla Release derlemesi vb.)
        // hemen silmek yerine diğer APNs ortamını (development <-> production) dene:
        if (result.reason === 'BadDeviceToken' || result.reason === 'BadEnvironmentKeyInToken') {
          const altEnv: ApnsEnvironment =
            currentEnv === 'production' ? 'development' : 'production';
          this.opts.log?.(
            `hesap ${account.id}: ${currentEnv} ortamında ${result.reason} alındı, alternatif ${altEnv} deneniyor...`,
          );
          const altResult = await this.apns.send(device.push_token, altEnv, payload);
          if (altResult.status === 'sent') {
            this.opts.log?.(
              `hesap ${account.id}: Alternatif ortamda (${altEnv}) push BAŞARIYLA gönderildi! Cihaz ortamı güncelleniyor.`,
            );
            this.repo.updateDeviceEnvironment(device.id, altEnv);
            return;
          }
        }

        this.opts.log?.(
          `hesap ${account.id}: APNs token'ı geçersiz sayıldı (${result.reason}), cihaz siliniyor`,
        );
        const ids = this.repo.deleteDevice(device.push_token);
        if (ids.length > 0) this.opts.onDevicesRemoved?.(ids);
        return;
      }
      const delay = RETRY_DELAYS_MS[attempt];
      if (!result.retryable || delay === undefined) {
        this.opts.log?.(`hesap ${account.id}: push gönderilemedi (${result.reason})`);
        return;
      }
      await this.sleep(delay);
    }
  }

  /**
   * Android: yalnızca-veri FCM mesajı. Bildirim metni (gönderen, konu)
   * GÖNDERİLMEZ; uygulama uyanınca iletiyi kendisi IMAP'ten çeker ve yerel
   * bildirimi üretir. Böylece ileti içeriği Google'dan geçmez ve eylem
   * düğmeleri/gruplama yerel bildirimle aynı kalır. `count` yalnızca
   * uygulamanın kaç ileti beklediğini bilmesi içindir.
   */
  private async notifyAndroid(
    account: AccountRow,
    device: DeviceRow,
    messages: NewMessage[],
    uidValidity?: number,
  ): Promise<void> {
    const fcm = this.opts.fcm;
    if (!fcm) {
      this.opts.log?.(`hesap ${account.id}: FCM yapılandırılmamış, push atlandı`);
      return;
    }
    const latest = messages[messages.length - 1]!;
    const data: Record<string, string> = {
      type: 'new_mail',
      accountId: String(account.client_account_id),
      folder: 'INBOX',
      uid: String(latest.uid),
      count: String(messages.length),
      ...(uidValidity !== undefined ? { uidValidity: String(uidValidity) } : {}),
    };
    // Aynı hesaba art arda gelen push'lar tek mesaja indirgenir; uygulama
    // zaten tüm yeni iletileri tek turda çeker.
    const options = { collapseKey: `account-${account.client_account_id}` };

    for (let attempt = 0; ; attempt++) {
      const result = await fcm.send(device.push_token, data, options);
      if (result.status === 'sent') {
        this.opts.log?.(`hesap ${account.id}: FCM push gönderildi`);
        return;
      }
      if (result.status === 'invalid_token') {
        this.opts.log?.(
          `hesap ${account.id}: FCM token'ı geçersiz sayıldı (${result.reason}), cihaz siliniyor`,
        );
        const ids = this.repo.deleteDevice(device.push_token);
        if (ids.length > 0) this.opts.onDevicesRemoved?.(ids);
        return;
      }
      const delay = RETRY_DELAYS_MS[attempt];
      if (!result.retryable || delay === undefined) {
        this.opts.log?.(`hesap ${account.id}: FCM push gönderilemedi (${result.reason})`);
        return;
      }
      await this.sleep(delay);
    }
  }
}
