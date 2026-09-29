import { createHash } from 'node:crypto';
import type Database from 'better-sqlite3';
import { TranslateProviderError, type TranslateProvider } from './azure-translator.js';

export interface TranslationLimits {
  /** Aylık genel sert sınır (karakter). Aşılacak istek Azure'a GİTMEZ. */
  monthlyLimit: number;
  /** Bu değere ulaşınca istemciye "limite yaklaşıldı" uyarısı döner. */
  warningLimit: number;
  /** Kullanıcı başına aylık sınır; genel sınırdan bağımsız denetlenir. */
  userMonthlyLimit: number;
  /** Tek istekte (konu + metin parçaları) izin verilen en çok karakter. */
  maxRequestChars: number;
  /** Azure isteği başına en çok parça / karakter (Azure sınırı: 1000 öğe / 50.000 karakter). */
  batchMaxSegments: number;
  batchMaxChars: number;
}

// Azure'un sınırlarının (1000 öğe, 50.000 karakter) altında güvenlik payıyla.
export const defaultBatchLimits = { batchMaxSegments: 500, batchMaxChars: 40_000 };

/** Kullanıcı kotasının bu oranından sonra uyarı verilir. */
const USER_WARNING_RATIO = 0.8;

/** Unicode kod noktası sayısı — kota bu şekilde sayılır. */
export function countCharacters(text: string): number {
  let n = 0;
  for (const _ of text) n++;
  return n;
}

export function monthKey(date: Date): string {
  return date.toISOString().slice(0, 7);
}

interface UsageRow {
  reserved_characters: number;
  consumed_characters: number;
}

export type ReserveResult = { ok: true } | { ok: false; reason: 'global' | 'user' };

export interface CachedTranslation {
  sourceHash: string;
  translatedSubject: string;
  translatedSegments: string[];
}

/**
 * Çeviri kullanımı ve önbelleği. better-sqlite3 eşzamanlıdır; `IMMEDIATE`
 * işlemler yazma kilidini başta alır, bu yüzden "oku-kontrol et-ayır" adımı
 * (bkz. [reserve]) iki eşzamanlı istek arasında bölünemez.
 */
export class TranslationStore {
  constructor(private readonly db: Database.Database) {}

  getCache(
    userId: string,
    messageId: string,
    source: string,
    target: string,
  ): CachedTranslation | undefined {
    const row = this.db
      .prepare(
        `SELECT source_hash, translated_subject, translated_segments
         FROM translated_email_cache
         WHERE user_id = ? AND message_id = ? AND source_language = ? AND target_language = ?`,
      )
      .get(userId, messageId, source, target) as
      | { source_hash: string; translated_subject: string; translated_segments: string }
      | undefined;
    if (!row) return undefined;
    try {
      return {
        sourceHash: row.source_hash,
        translatedSubject: row.translated_subject,
        translatedSegments: JSON.parse(row.translated_segments) as string[],
      };
    } catch {
      return undefined;
    }
  }

  putCache(
    userId: string,
    messageId: string,
    source: string,
    target: string,
    value: CachedTranslation,
    now: number,
  ): void {
    this.db
      .prepare(
        `INSERT INTO translated_email_cache
           (user_id, message_id, source_language, target_language, source_hash,
            translated_subject, translated_segments, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(user_id, message_id, source_language, target_language) DO UPDATE SET
           source_hash = excluded.source_hash,
           translated_subject = excluded.translated_subject,
           translated_segments = excluded.translated_segments,
           updated_at = excluded.updated_at`,
      )
      .run(
        userId,
        messageId,
        source,
        target,
        value.sourceHash,
        value.translatedSubject,
        JSON.stringify(value.translatedSegments),
        now,
        now,
      );
  }

  /** Eski önbellek kayıtlarını siler; kullanım tablolarına dokunmaz. */
  pruneCache(olderThan: number): number {
    return this.db
      .prepare('DELETE FROM translated_email_cache WHERE updated_at < ?')
      .run(olderThan).changes;
  }

  /**
   * Genel VE kullanıcı sınırını tek işlemde denetler ve geçerse `chars`
   * karakteri ayırır. Kullanım = harcanan + ayrılan; ayrılan karakterler de
   * sayıldığı için eşzamanlı istekler toplamı aşamaz.
   */
  reserve(
    userId: string,
    month: string,
    chars: number,
    limits: Pick<TranslationLimits, 'monthlyLimit' | 'userMonthlyLimit'>,
    now: number,
  ): ReserveResult {
    const tx = this.db.transaction((): ReserveResult => {
      const g = this.globalRow(month);
      if (g.reserved_characters + g.consumed_characters + chars > limits.monthlyLimit) {
        return { ok: false, reason: 'global' };
      }
      const u = this.userRow(userId, month);
      if (u.reserved_characters + u.consumed_characters + chars > limits.userMonthlyLimit) {
        return { ok: false, reason: 'user' };
      }
      this.db
        .prepare(
          `INSERT INTO translation_usage (month, reserved_characters, updated_at)
           VALUES (?, ?, ?)
           ON CONFLICT(month) DO UPDATE SET
             reserved_characters = reserved_characters + excluded.reserved_characters,
             updated_at = excluded.updated_at`,
        )
        .run(month, chars, now);
      this.db
        .prepare(
          `INSERT INTO user_translation_usage (user_id, month, reserved_characters, updated_at)
           VALUES (?, ?, ?, ?)
           ON CONFLICT(user_id, month) DO UPDATE SET
             reserved_characters = reserved_characters + excluded.reserved_characters,
             updated_at = excluded.updated_at`,
        )
        .run(userId, month, chars, now);
      return { ok: true };
    });
    return tx.immediate();
  }

  /**
   * Ayrılan `reserved` karakteri kapatır: `consumed` kadarı harcanmış sayılır,
   * kalanı iade edilir (Azure'a hiç gitmediyse `consumed = 0`).
   */
  settle(userId: string, month: string, reserved: number, consumed: number, now: number): void {
    const tx = this.db.transaction(() => {
      this.db
        .prepare(
          `UPDATE translation_usage SET
             reserved_characters = MAX(0, reserved_characters - ?),
             consumed_characters = consumed_characters + ?,
             request_count = request_count + ?,
             updated_at = ?
           WHERE month = ?`,
        )
        .run(reserved, consumed, consumed > 0 ? 1 : 0, now, month);
      this.db
        .prepare(
          `UPDATE user_translation_usage SET
             reserved_characters = MAX(0, reserved_characters - ?),
             consumed_characters = consumed_characters + ?,
             request_count = request_count + ?,
             updated_at = ?
           WHERE user_id = ? AND month = ?`,
        )
        .run(reserved, consumed, consumed > 0 ? 1 : 0, now, userId, month);
    });
    tx.immediate();
  }

  /**
   * Açılışta: önceki çalışma yanıt beklerken kapanmışsa ayrılmış kalan
   * karakterlerin Azure'da işlenip işlenmediği bilinemez — güvenli tarafta
   * kalıp harcanmış sayılır.
   */
  settleStaleReservations(now: number): void {
    const tx = this.db.transaction(() => {
      for (const table of ['translation_usage', 'user_translation_usage']) {
        this.db
          .prepare(
            `UPDATE ${table} SET
               consumed_characters = consumed_characters + reserved_characters,
               reserved_characters = 0,
               updated_at = ?
             WHERE reserved_characters > 0`,
          )
          .run(now);
      }
    });
    tx.immediate();
  }

  usedGlobal(month: string): number {
    const g = this.globalRow(month);
    return g.reserved_characters + g.consumed_characters;
  }

  usedByUser(userId: string, month: string): number {
    const u = this.userRow(userId, month);
    return u.reserved_characters + u.consumed_characters;
  }

  private globalRow(month: string): UsageRow {
    return (
      (this.db
        .prepare(
          'SELECT reserved_characters, consumed_characters FROM translation_usage WHERE month = ?',
        )
        .get(month) as UsageRow | undefined) ?? { reserved_characters: 0, consumed_characters: 0 }
    );
  }

  private userRow(userId: string, month: string): UsageRow {
    return (
      (this.db
        .prepare(
          `SELECT reserved_characters, consumed_characters FROM user_translation_usage
           WHERE user_id = ? AND month = ?`,
        )
        .get(userId, month) as UsageRow | undefined) ?? {
        reserved_characters: 0,
        consumed_characters: 0,
      }
    );
  }
}

export interface TranslateInput {
  userId: string;
  messageId: string;
  sourceLanguage: string;
  targetLanguage: string;
  subject: string;
  segments: string[];
}

export type TranslationErrorCode =
  | 'TRANSLATION_MONTHLY_LIMIT_REACHED'
  | 'TRANSLATION_USER_LIMIT_REACHED'
  | 'TRANSLATION_TOO_LARGE'
  | 'TRANSLATION_UNAVAILABLE';

export type TranslateOutcome =
  | {
      ok: true;
      translatedSubject: string;
      segments: string[];
      cacheHit: boolean;
      /** Aylık kullanım uyarı eşiğine yaklaştı. */
      nearLimit: boolean;
    }
  | { ok: false; code: TranslationErrorCode; status: 413 | 429 | 503 };

export type DetectOutcome =
  | { ok: true; language: string | null; score: number; nearLimit: boolean }
  | { ok: false; code: TranslationErrorCode; status: 413 | 429 | 503 };

/** Dil algılama için Azure'a gönderilen en çok karakter (kota tasarrufu). */
export const DETECT_SAMPLE_CHARS = 400;

export interface TranslationServiceOptions {
  store: TranslationStore;
  /** `null`: Azure anahtarı tanımlı değil ya da özellik kapalı — önbellek çalışır, yeni çeviri yapılmaz. */
  provider: TranslateProvider | null;
  limits: TranslationLimits;
  now?: () => Date;
  /** İçerik ASLA loglanmaz: yalnızca dil, karakter sayısı, süre. */
  log?: (message: string) => void;
}

function isBlank(text: string): boolean {
  return text.trim().length === 0;
}

/**
 * Önbellek-öncelikli çeviri akışı:
 * önbellek → karakter hesabı → genel/kullanıcı limiti → atomik ayırma →
 * Azure (parçalı) → önbelleğe yaz. Ayırma başarısızsa Azure'a hiç gidilmez.
 */
export class TranslationService {
  private readonly now: () => Date;

  constructor(private readonly opts: TranslationServiceOptions) {
    this.now = opts.now ?? (() => new Date());
  }

  async translate(input: TranslateInput): Promise<TranslateOutcome> {
    const started = Date.now();
    const { store, provider, limits } = this.opts;
    const finish = (outcome: TranslateOutcome, chars: number, cacheHit: boolean) => {
      this.opts.log?.(
        `translation request source=${input.sourceLanguage} target=${input.targetLanguage} ` +
          `characters=${chars} cacheHit=${cacheHit} ok=${outcome.ok}` +
          `${outcome.ok ? '' : ` code=${outcome.code}`} duration=${Date.now() - started}ms`,
      );
      return outcome;
    };

    const sourceHash = hashSource(input.subject, input.segments);
    const nowDate = this.now();
    const month = monthKey(nowDate);
    const nowMs = nowDate.getTime();

    // 1) Önbellek — Azure'dan ve tüm limit kontrollerinden ÖNCE.
    const cached = store.getCache(
      input.userId,
      input.messageId,
      input.sourceLanguage,
      input.targetLanguage,
    );
    if (
      cached &&
      cached.sourceHash === sourceHash &&
      cached.translatedSegments.length === input.segments.length
    ) {
      return finish(
        {
          ok: true,
          translatedSubject: cached.translatedSubject,
          segments: cached.translatedSegments,
          cacheHit: true,
          nearLimit: this.nearLimit(input.userId, month),
        },
        0,
        true,
      );
    }

    // 2) Karakter hesabı: yalnızca Azure'a gerçekten gidecek metin. Boş
    // parçalar gönderilmez; aynı metin (ör. tekrarlanan "Click here") bir kez.
    const unique: string[] = [];
    const indexOf = new Map<string, number>();
    for (const text of [input.subject, ...input.segments]) {
      if (isBlank(text) || indexOf.has(text)) continue;
      indexOf.set(text, unique.length);
      unique.push(text);
    }
    const sizes = unique.map(countCharacters);
    const chars = sizes.reduce((a, b) => a + b, 0);

    // Tek bir parça Azure'un istek başına karakter sınırından büyükse hiçbir
    // gruba sığmaz; boşuna kota ayırmadan reddedilir.
    if (chars > limits.maxRequestChars || sizes.some((n) => n > limits.batchMaxChars)) {
      return finish({ ok: false, code: 'TRANSLATION_TOO_LARGE', status: 413 }, chars, false);
    }
    if (!provider) {
      return finish({ ok: false, code: 'TRANSLATION_UNAVAILABLE', status: 503 }, chars, false);
    }

    let translatedUnique: string[] = [];
    if (chars > 0) {
      // 3) Genel + kullanıcı limiti ve atomik ayırma.
      const reservation = store.reserve(input.userId, month, chars, limits, nowMs);
      if (!reservation.ok) {
        return finish(
          {
            ok: false,
            code:
              reservation.reason === 'global'
                ? 'TRANSLATION_MONTHLY_LIMIT_REACHED'
                : 'TRANSLATION_USER_LIMIT_REACHED',
            status: 429,
          },
          chars,
          false,
        );
      }

      // 4) Azure — limit aşımını önlemek için parçalar sırayla gider.
      let processed = 0;
      let inFlight = 0;
      try {
        for (const batch of makeBatches(unique, sizes, limits)) {
          const source = input.sourceLanguage === 'auto' ? undefined : input.sourceLanguage;
          inFlight = batch.chars;
          const out = await provider.translate(batch.texts, input.targetLanguage, source);
          if (out.length !== batch.texts.length) {
            throw new TranslateProviderError('Sağlayıcı yanıt uzunluğu uyuşmuyor', false);
          }
          translatedUnique = translatedUnique.concat(out);
          processed += batch.chars;
          inFlight = 0;
        }
      } catch (e) {
        // Yalnızca başarısız parça belirsiz olabilir; işlenmemiş kalan parçalar
        // hiç gönderilmediği için iade edilir. Kesin işlenmediyse o parça da.
        const definite = e instanceof TranslateProviderError && e.definitelyNotProcessed;
        store.settle(
          input.userId,
          month,
          chars,
          definite ? processed : processed + inFlight,
          nowMs,
        );
        return finish({ ok: false, code: 'TRANSLATION_UNAVAILABLE', status: 503 }, chars, false);
      }
      store.settle(input.userId, month, chars, chars, nowMs);
    }

    const lookup = (text: string): string => {
      const i = indexOf.get(text);
      return i === undefined ? text : (translatedUnique[i] ?? text);
    };
    const translatedSubject = lookup(input.subject);
    const segments = input.segments.map(lookup);

    store.putCache(
      input.userId,
      input.messageId,
      input.sourceLanguage,
      input.targetLanguage,
      { sourceHash, translatedSubject, translatedSegments: segments },
      nowMs,
    );
    return finish(
      {
        ok: true,
        translatedSubject,
        segments,
        cacheHit: false,
        nearLimit: this.nearLimit(input.userId, month),
      },
      chars,
      false,
    );
  }

  /**
   * Metnin dilini algılar. Azure algılama isteklerini de karakter sayar; bu
   * yüzden örnek kısa tutulur ([DETECT_SAMPLE_CHARS]) ve aynı genel/kullanıcı
   * limit + atomik ayırma yolundan geçer. İçerik loglanmaz.
   */
  async detect(input: { userId: string; sample: string }): Promise<DetectOutcome> {
    const started = Date.now();
    const { store, provider, limits } = this.opts;
    const sample = Array.from(input.sample.trim()).slice(0, DETECT_SAMPLE_CHARS).join('');
    const chars = countCharacters(sample);
    const finish = (outcome: DetectOutcome) => {
      this.opts.log?.(
        `translation detect characters=${chars} ok=${outcome.ok}` +
          `${outcome.ok ? ` language=${outcome.language ?? 'none'}` : ` code=${outcome.code}`} ` +
          `duration=${Date.now() - started}ms`,
      );
      return outcome;
    };

    const nowDate = this.now();
    const month = monthKey(nowDate);
    const nowMs = nowDate.getTime();
    if (chars === 0) {
      return finish({ ok: true, language: null, score: 0, nearLimit: false });
    }
    if (!provider) {
      return finish({ ok: false, code: 'TRANSLATION_UNAVAILABLE', status: 503 });
    }
    const reservation = store.reserve(input.userId, month, chars, limits, nowMs);
    if (!reservation.ok) {
      return finish({
        ok: false,
        code:
          reservation.reason === 'global'
            ? 'TRANSLATION_MONTHLY_LIMIT_REACHED'
            : 'TRANSLATION_USER_LIMIT_REACHED',
        status: 429,
      });
    }
    try {
      const detected = await provider.detect(sample);
      store.settle(input.userId, month, chars, chars, nowMs);
      return finish({
        ok: true,
        language: detected.language,
        score: detected.score,
        nearLimit: this.nearLimit(input.userId, month),
      });
    } catch (e) {
      const definite = e instanceof TranslateProviderError && e.definitelyNotProcessed;
      store.settle(input.userId, month, chars, definite ? 0 : chars, nowMs);
      return finish({ ok: false, code: 'TRANSLATION_UNAVAILABLE', status: 503 });
    }
  }

  private nearLimit(userId: string, month: string): boolean {
    const { store, limits } = this.opts;
    return (
      store.usedGlobal(month) >= limits.warningLimit ||
      store.usedByUser(userId, month) >= limits.userMonthlyLimit * USER_WARNING_RATIO
    );
  }
}

function hashSource(subject: string, segments: string[]): string {
  return createHash('sha256').update(JSON.stringify([subject, segments])).digest('hex');
}

function makeBatches(
  texts: string[],
  sizes: number[],
  limits: Pick<TranslationLimits, 'batchMaxSegments' | 'batchMaxChars'>,
): { texts: string[]; chars: number }[] {
  const batches: { texts: string[]; chars: number }[] = [];
  let current: { texts: string[]; chars: number } = { texts: [], chars: 0 };
  texts.forEach((text, i) => {
    const size = sizes[i]!;
    if (
      current.texts.length > 0 &&
      (current.texts.length >= limits.batchMaxSegments ||
        current.chars + size > limits.batchMaxChars)
    ) {
      batches.push(current);
      current = { texts: [], chars: 0 };
    }
    current.texts.push(text);
    current.chars += size;
  });
  if (current.texts.length > 0) batches.push(current);
  return batches;
}
