import { beforeEach, describe, expect, it, vi } from 'vitest';
import { buildApp } from '../src/app.js';
import { SecretBox } from '../src/crypto.js';
import { openDatabase } from '../src/db.js';
import { AzureTranslatorProvider, TranslateProviderError } from '../src/azure-translator.js';
import type { DetectedLanguage, TranslateProvider } from '../src/azure-translator.js';
import { Repository } from '../src/repository.js';
import {
  TranslationService,
  TranslationStore,
  countCharacters,
  defaultBatchLimits,
  type TranslateInput,
  type TranslationLimits,
} from '../src/translation.js';

const limits: TranslationLimits = {
  monthlyLimit: 1_800_000,
  warningLimit: 1_600_000,
  userMonthlyLimit: 10_000_000, // genel limiti sınamak için kullanıcı limiti yüksek
  maxRequestChars: 2_000_000,
  ...defaultBatchLimits,
};

class FakeProvider implements TranslateProvider {
  calls: string[][] = [];
  fail: TranslateProviderError | null = null;
  delayMs = 0;
  async translate(texts: string[]): Promise<string[]> {
    this.calls.push(texts);
    if (this.delayMs) await new Promise((r) => setTimeout(r, this.delayMs));
    if (this.fail) throw this.fail;
    return texts.map((t) => `tr:${t}`);
  }
  async detect(_text: string): Promise<DetectedLanguage> {
    return { language: 'en', score: 0.99 };
  }
}

function setup(over: Partial<TranslationLimits> = {}, now = () => new Date('2026-09-15T10:00:00Z')) {
  const db = openDatabase(':memory:');
  const store = new TranslationStore(db);
  const provider = new FakeProvider();
  const service = new TranslationService({
    store,
    provider,
    limits: { ...limits, ...over },
    now,
  });
  return { db, store, provider, service };
}

const input = (over: Partial<TranslateInput> = {}): TranslateInput => ({
  userId: 'user-000001',
  messageId: 'abc123',
  sourceLanguage: 'en',
  targetLanguage: 'tr',
  subject: 'Hello',
  segments: ['Welcome to our service', 'Click here'],
  ...over,
});

/** Tam `n` karakterlik tek parça. */
const chunk = (n: number) => 'a'.repeat(n);

describe('önbellek', () => {
  it('aynı mail ikinci kez çevrilirse Azure çağrılmaz', async () => {
    const s = setup();
    const first = await s.service.translate(input());
    const second = await s.service.translate(input());
    expect(first.ok && first.cacheHit).toBe(false);
    expect(second.ok && second.cacheHit).toBe(true);
    expect(s.provider.calls).toHaveLength(1);
    expect(second.ok && second.segments).toEqual(['tr:Welcome to our service', 'tr:Click here']);
  });

  it('farklı hedef dil için yeni çeviri yapılır', async () => {
    const s = setup();
    await s.service.translate(input());
    await s.service.translate(input({ targetLanguage: 'de' }));
    expect(s.provider.calls).toHaveLength(2);
  });

  it('farklı messageId için yeni çeviri yapılır', async () => {
    const s = setup();
    await s.service.translate(input());
    await s.service.translate(input({ messageId: 'other' }));
    expect(s.provider.calls).toHaveLength(2);
  });

  it('başka kullanıcı aynı messageId ile başkasının çevirisini görmez', async () => {
    const s = setup();
    await s.service.translate(input());
    await s.service.translate(input({ userId: 'user-000002' }));
    expect(s.provider.calls).toHaveLength(2);
  });

  it('içerik değişmişse eski çeviri sunulmaz', async () => {
    const s = setup();
    await s.service.translate(input());
    await s.service.translate(input({ segments: ['Başka içerik'] }));
    expect(s.provider.calls).toHaveLength(2);
  });

  it('önbellek limit dolu olsa bile çalışır', async () => {
    const s = setup({ monthlyLimit: 60, warningLimit: 50 });
    const ok = await s.service.translate(input()); // 5 + 22 + 10 = 37
    expect(ok.ok).toBe(true);
    const other = await s.service.translate(input({ messageId: 'x' }));
    expect(other.ok).toBe(false);
    const again = await s.service.translate(input());
    expect(again.ok && again.cacheHit).toBe(true);
  });

  it('duplicate kayıt oluşmaz', async () => {
    const s = setup();
    await s.service.translate(input());
    await s.service.translate(input({ segments: ['Yeni'] }));
    const n = s.db.prepare('SELECT COUNT(*) AS n FROM translated_email_cache').get() as {
      n: number;
    };
    expect(n.n).toBe(1);
  });
});

describe('karakter hesabı', () => {
  it('yalnızca gönderilen metin sayılır; konu dahil, boş ve tekrar edenler hariç', async () => {
    const s = setup();
    await s.service.translate(
      input({ subject: 'Hi', segments: ['Hello', '   ', 'Hello', 'Bye', ''] }),
    );
    expect(s.provider.calls).toEqual([['Hi', 'Hello', 'Bye']]);
    expect(s.store.usedGlobal('2026-09')).toBe(2 + 5 + 3);
    expect(s.store.usedByUser('user-000001', '2026-09')).toBe(10);
  });

  it('kod noktası sayar (emoji tek karakter)', () => {
    expect(countCharacters('a😀b')).toBe(3);
  });

  it('boş/boşluk parçalar ve konu aynen döner', async () => {
    const s = setup();
    const r = await s.service.translate(input({ subject: '', segments: [' ', 'Hi'] }));
    expect(r.ok && r.translatedSubject).toBe('');
    expect(r.ok && r.segments).toEqual([' ', 'tr:Hi']);
  });
});

/** Toplamı tam `total` karakter olan, birbirinden farklı (tekilleştirilemeyen) parçalar. */
const many = (total: number, size = 10_000, tag = 'a') => {
  const out: string[] = [];
  for (let i = 0; total > 0; i++) {
    const n = Math.min(size, total);
    out.push(`${tag}${i}`.padEnd(n, '.').slice(0, n));
    total -= n;
  }
  return out;
};

describe('limit', () => {
  it('1.600.000 karakter → başarılı', async () => {
    const s = setup();
    const r = await s.service.translate(input({ subject: '', segments: many(1_600_000) }));
    expect(r.ok).toBe(true);
    expect(s.store.usedGlobal('2026-09')).toBe(1_600_000);
  });

  it('1.799.000 + 500 → başarılı', async () => {
    const s = setup();
    await s.service.translate(input({ messageId: 'm1', subject: '', segments: many(1_799_000) }));
    const r = await s.service.translate(
      input({ messageId: 'm2', subject: '', segments: many(500, 500, 'b') }),
    );
    expect(r.ok).toBe(true);
  });

  it('1.799.000 + 2.000 → reddedilir ve Azure çağrılmaz', async () => {
    const s = setup();
    await s.service.translate(input({ messageId: 'm1', subject: '', segments: many(1_799_000) }));
    const calls = s.provider.calls.length;
    const r = await s.service.translate(
      input({ messageId: 'm2', subject: '', segments: many(2_000, 2_000, 'b') }),
    );
    expect(r).toEqual({ ok: false, code: 'TRANSLATION_MONTHLY_LIMIT_REACHED', status: 429 });
    expect(s.provider.calls).toHaveLength(calls);
    expect(s.store.usedGlobal('2026-09')).toBe(1_799_000);
  });

  it('tam limite kadar izin verir, bir fazlasını reddeder', async () => {
    const s = setup({ monthlyLimit: 10, warningLimit: 5 });
    const a = await s.service.translate(input({ subject: '', segments: [chunk(10)] }));
    const b = await s.service.translate(input({ messageId: 'b', subject: '', segments: ['b'] }));
    expect(a.ok).toBe(true);
    expect(b.ok).toBe(false);
  });

  it('limit dolunca Azure hiç çağrılmaz', async () => {
    const s = setup({ monthlyLimit: 0, warningLimit: 0 });
    const r = await s.service.translate(input());
    expect(r.ok).toBe(false);
    expect(s.provider.calls).toHaveLength(0);
  });

  it('kullanıcı limiti genel limitten bağımsız denetlenir', async () => {
    const s = setup({ userMonthlyLimit: 50 });
    const a = await s.service.translate(input({ subject: '', segments: [chunk(40)] }));
    const b = await s.service.translate(input({ messageId: 'b', subject: '', segments: ['b'.repeat(20)] }));
    const other = await s.service.translate(
      input({ userId: 'user-000002', messageId: 'c', subject: '', segments: ['c'.repeat(20)] }),
    );
    expect(a.ok).toBe(true);
    expect(b).toEqual({ ok: false, code: 'TRANSLATION_USER_LIMIT_REACHED', status: 429 });
    expect(other.ok).toBe(true);
  });

  it('çok büyük istek TRANSLATION_TOO_LARGE ile reddedilir', async () => {
    const s = setup({ maxRequestChars: 100 });
    const r = await s.service.translate(input({ subject: '', segments: [chunk(101)] }));
    expect(r).toEqual({ ok: false, code: 'TRANSLATION_TOO_LARGE', status: 413 });
    expect(s.provider.calls).toHaveLength(0);
  });

  it('uyarı eşiğinde nearLimit true olur', async () => {
    const s = setup({ monthlyLimit: 100, warningLimit: 50 });
    const low = await s.service.translate(input({ subject: '', segments: [chunk(10)] }));
    const high = await s.service.translate(
      input({ messageId: 'b', subject: '', segments: ['b'.repeat(45)] }),
    );
    expect(low.ok && low.nearLimit).toBe(false);
    expect(high.ok && high.nearLimit).toBe(true);
  });

  it('ay değişince kullanım sıfırdan başlar, eski kayıt kalır', async () => {
    let date = new Date('2026-09-30T23:00:00Z');
    const s = setup({ monthlyLimit: 10, warningLimit: 5 }, () => date);
    await s.service.translate(input({ subject: '', segments: [chunk(10)] }));
    expect((await s.service.translate(input({ messageId: 'b', subject: '', segments: ['b'] }))).ok).toBe(false);
    date = new Date('2026-10-01T00:30:00Z');
    expect((await s.service.translate(input({ messageId: 'c', subject: '', segments: ['c'] }))).ok).toBe(true);
    expect(s.store.usedGlobal('2026-09')).toBe(10);
    expect(s.store.usedGlobal('2026-10')).toBe(1);
  });
});

describe('eşzamanlı istekler', () => {
  it('iki eşzamanlı istek toplam limiti aşmaz', async () => {
    const s = setup({ monthlyLimit: 100, warningLimit: 50 });
    s.provider.delayMs = 20;
    const [a, b] = await Promise.all([
      s.service.translate(input({ messageId: 'a', subject: '', segments: [chunk(60)] })),
      s.service.translate(input({ messageId: 'b', subject: '', segments: ['b'.repeat(60)] })),
    ]);
    expect([a.ok, b.ok].filter(Boolean)).toHaveLength(1);
    expect(s.provider.calls).toHaveLength(1);
    expect(s.store.usedGlobal('2026-09')).toBe(60);
  });

  it('işlem sürerken ayrılan karakterler de sayılır', async () => {
    const s = setup({ monthlyLimit: 100, warningLimit: 50 });
    s.provider.delayMs = 20;
    const first = s.service.translate(input({ messageId: 'a', subject: '', segments: [chunk(90)] }));
    const second = await s.service.translate(input({ messageId: 'b', subject: '', segments: ['b'.repeat(20)] }));
    expect(second.ok).toBe(false);
    expect((await first).ok).toBe(true);
  });
});

describe('Azure başarısızlığı', () => {
  it('kesin işlenmediyse kota iade edilir, önbelleğe yazılmaz, çökmez', async () => {
    const s = setup();
    s.provider.fail = new TranslateProviderError('HTTP 500', true);
    const r = await s.service.translate(input());
    expect(r).toEqual({ ok: false, code: 'TRANSLATION_UNAVAILABLE', status: 503 });
    expect(s.store.usedGlobal('2026-09')).toBe(0);
    expect(s.store.usedByUser('user-000001', '2026-09')).toBe(0);
    s.provider.fail = null;
    const retry = await s.service.translate(input());
    expect(retry.ok && retry.cacheHit).toBe(false);
  });

  it('belirsizse (zaman aşımı) karakterler harcanmış sayılır', async () => {
    const s = setup();
    s.provider.fail = new TranslateProviderError('timeout', false);
    const r = await s.service.translate(input());
    expect(r.ok).toBe(false);
    expect(s.store.usedGlobal('2026-09')).toBe(37);
  });

  it('beklenmeyen hata da güvenli tarafta harcanmış sayılır', async () => {
    const s = setup();
    s.provider.translate = vi.fn().mockRejectedValue(new Error('boom'));
    const r = await s.service.translate(input());
    expect(r.ok).toBe(false);
    expect(s.store.usedGlobal('2026-09')).toBe(37);
  });

  it('ayrılmış karakter açılışta harcanmış sayılır', async () => {
    const s = setup();
    s.store.reserve('user-000001', '2026-09', 30, limits, Date.now());
    s.store.settleStaleReservations(Date.now());
    expect(s.store.usedGlobal('2026-09')).toBe(30);
    const row = s.db.prepare('SELECT reserved_characters r FROM translation_usage').get() as { r: number };
    expect(row.r).toBe(0);
  });

  it('sağlayıcı yoksa TRANSLATION_UNAVAILABLE (önbellek yine çalışır)', async () => {
    const s = setup();
    await s.service.translate(input());
    const noProvider = new TranslationService({ store: s.store, provider: null, limits });
    expect((await noProvider.translate(input())).ok).toBe(true);
    const r = await noProvider.translate(input({ messageId: 'new' }));
    expect(r).toEqual({ ok: false, code: 'TRANSLATION_UNAVAILABLE', status: 503 });
  });
});

describe('parçalama', () => {
  it('çok parça tek istekte değil, sınırlara göre bölünür', async () => {
    const s = setup({ batchMaxSegments: 3 });
    const segments = Array.from({ length: 7 }, (_, i) => `s${i}`);
    const r = await s.service.translate(input({ subject: '', segments }));
    expect(r.ok && r.segments).toEqual(segments.map((t) => `tr:${t}`));
    expect(s.provider.calls.map((c) => c.length)).toEqual([3, 3, 1]);
  });

  it('karakter sınırına göre bölünür', async () => {
    const s = setup({ batchMaxChars: 10 });
    await s.service.translate(input({ subject: '', segments: ['aaaaaa', 'bbbbbb', 'cc'] }));
    expect(s.provider.calls).toEqual([['aaaaaa'], ['bbbbbb', 'cc']]);
  });

  it('ortadaki parça başarısız olursa yalnızca işlenenler harcanır', async () => {
    const s = setup({ batchMaxChars: 10 });
    let n = 0;
    s.provider.translate = async (texts: string[]) => {
      if (++n === 2) throw new TranslateProviderError('HTTP 400', true);
      return texts.map((t) => `tr:${t}`);
    };
    const r = await s.service.translate(input({ subject: '', segments: ['aaaaaa', 'bbbbbb', 'cc'] }));
    expect(r.ok).toBe(false);
    expect(s.store.usedGlobal('2026-09')).toBe(6);
  });
});

describe('AzureTranslatorProvider', () => {
  const azure = (fetchMock: unknown, over: Record<string, unknown> = {}) =>
    new AzureTranslatorProvider({
      endpoint: 'https://api.cognitive.microsofttranslator.com',
      key: 'SECRET',
      region: 'westeurope',
      fetchImpl: fetchMock as typeof fetch,
      ...over,
    });
  const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });

  it('anahtarı başlıkta gönderir, URL’de değil; Text dizisi + düz metin', async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValue(json([{ translations: [{ text: 'Merhaba', to: 'tr' }] }]));
    expect(await azure(fetchMock).translate(['Hello'], 'tr', 'en')).toEqual(['Merhaba']);
    const [url, init] = fetchMock.mock.calls[0]!;
    expect(String(url)).not.toContain('SECRET');
    expect(String(url)).toContain('https://api.cognitive.microsofttranslator.com/translate?');
    expect(String(url)).toContain('api-version=3.0');
    expect(String(url)).toContain('to=tr');
    expect(String(url)).toContain('from=en');
    expect(String(url)).toContain('textType=plain');
    expect(init.headers['ocp-apim-subscription-key']).toBe('SECRET');
    expect(init.headers['ocp-apim-subscription-region']).toBe('westeurope');
    expect(JSON.parse(init.body)).toEqual([{ Text: 'Hello' }]);
  });

  it('bölge yoksa bölge başlığı gönderilmez; kaynak yoksa from yok', async () => {
    const fetchMock = vi.fn().mockResolvedValue(json([{ translations: [{ text: 'x' }] }]));
    await azure(fetchMock, { region: undefined }).translate(['a'], 'tr');
    const [url, init] = fetchMock.mock.calls[0]!;
    expect(init.headers['ocp-apim-subscription-region']).toBeUndefined();
    expect(String(url)).not.toContain('from=');
  });

  it('özel alan adlı kaynakta yol /translator/text/v3.0/…', async () => {
    const fetchMock = vi.fn().mockResolvedValue(json([{ translations: [{ text: 'x' }] }]));
    await azure(fetchMock, { endpoint: 'https://kaydet.cognitiveservices.azure.com' }).translate(['a'], 'tr');
    expect(String(fetchMock.mock.calls[0]![0])).toContain(
      'https://kaydet.cognitiveservices.azure.com/translator/text/v3.0/translate?',
    );
  });

  it('dil algılar', async () => {
    const fetchMock = vi.fn().mockResolvedValue(json([{ language: 'de', score: 0.98 }]));
    expect(await azure(fetchMock).detect('Hallo Welt')).toEqual({ language: 'de', score: 0.98 });
    expect(String(fetchMock.mock.calls[0]![0])).toContain('/detect?');
  });

  it.each([400, 401, 403, 429, 500])('HTTP %i kesin işlenmedi sayılır', async (status) => {
    const p = azure(vi.fn().mockResolvedValue(json({ error: {} }, status)));
    await expect(p.translate(['a'], 'tr')).rejects.toMatchObject({
      definitelyNotProcessed: true,
      status,
    });
  });

  it('ağ hatası/zaman aşımı ve bozuk yanıt belirsiz sayılır', async () => {
    const net = azure(vi.fn().mockRejectedValue(new Error('x')));
    await expect(net.translate(['a'], 'tr')).rejects.toMatchObject({ definitelyNotProcessed: false });
    const bad = azure(vi.fn().mockResolvedValue(json([{ translations: [] }])));
    await expect(bad.translate(['a'], 'tr')).rejects.toMatchObject({ definitelyNotProcessed: false });
    const short = azure(vi.fn().mockResolvedValue(json([])));
    await expect(short.translate(['a', 'b'], 'tr')).rejects.toMatchObject({ definitelyNotProcessed: false });
  });

  it('https olmayan uç nokta reddedilir', () => {
    expect(() => azure(vi.fn(), { endpoint: 'http://x.example.com' })).toThrow();
  });
});

describe('dil algılama (servis)', () => {
  it('algılar, örneği kısaltır ve karakteri sayar', async () => {
    const s = setup();
    const detect = vi.spyOn(s.provider, 'detect');
    const r = await s.service.detect({ userId: 'user-000001', sample: 'a'.repeat(1000) });
    expect(r.ok && r.language).toBe('en');
    expect(detect.mock.calls[0]![0]).toHaveLength(400);
    expect(s.store.usedGlobal('2026-09')).toBe(400);
  });

  it('boş örnek Azure’a gitmez', async () => {
    const s = setup();
    const detect = vi.spyOn(s.provider, 'detect');
    const r = await s.service.detect({ userId: 'user-000001', sample: '   ' });
    expect(r.ok && r.language).toBeNull();
    expect(detect).not.toHaveBeenCalled();
  });

  it('limit dolunca Azure çağrılmaz', async () => {
    const s = setup({ monthlyLimit: 10, warningLimit: 5 });
    const detect = vi.spyOn(s.provider, 'detect');
    const r = await s.service.detect({ userId: 'user-000001', sample: 'a'.repeat(50) });
    expect(r).toEqual({ ok: false, code: 'TRANSLATION_MONTHLY_LIMIT_REACHED', status: 429 });
    expect(detect).not.toHaveBeenCalled();
  });

  it('kesin hatada kota iade, belirsizde harcanmış', async () => {
    const s = setup();
    s.provider.detect = async () => {
      throw new TranslateProviderError('429', true, 429);
    };
    expect((await s.service.detect({ userId: 'user-000001', sample: 'hello' })).ok).toBe(false);
    expect(s.store.usedGlobal('2026-09')).toBe(0);
    s.provider.detect = async () => {
      throw new TranslateProviderError('timeout', false);
    };
    await s.service.detect({ userId: 'user-000001', sample: 'hello' });
    expect(s.store.usedGlobal('2026-09')).toBe(5);
  });

  it('POST /v1/translate/detect', async () => {
    const s = setup();
    const app = buildApp({
      repo: new Repository(s.db, new SecretBox('c'.repeat(64))),
      apiKey: 'k'.repeat(40),
      translation: s.service,
    });
    const res = await app.inject({
      method: 'POST',
      url: '/v1/translate/detect',
      headers: { authorization: `Bearer ${'k'.repeat(40)}` },
      payload: { userId: 'user-000001', sample: 'Hello there' },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ language: 'en' });
    const noAuth = await app.inject({
      method: 'POST',
      url: '/v1/translate/detect',
      payload: { userId: 'user-000001', sample: 'x' },
    });
    expect(noAuth.statusCode).toBe(401);
  });
});

describe('Azure hata senaryoları (servis)', () => {
  it('429 yanıtında kota iade edilir, çökmez', async () => {
    const s = setup();
    s.provider.fail = new TranslateProviderError('Azure HTTP 429', true, 429);
    const r = await s.service.translate(input());
    expect(r).toEqual({ ok: false, code: 'TRANSLATION_UNAVAILABLE', status: 503 });
    expect(s.store.usedGlobal('2026-09')).toBe(0);
  });

  it('zaman aşımında karakterler harcanmış sayılır', async () => {
    const s = setup();
    s.provider.fail = new TranslateProviderError('timeout', false);
    await s.service.translate(input());
    expect(s.store.usedGlobal('2026-09')).toBe(37);
  });

  it('tek parça Azure istek sınırından büyükse reddedilir', async () => {
    const s = setup({ batchMaxChars: 100 });
    const r = await s.service.translate(input({ subject: '', segments: [chunk(101)] }));
    expect(r).toEqual({ ok: false, code: 'TRANSLATION_TOO_LARGE', status: 413 });
    expect(s.provider.calls).toHaveLength(0);
  });
});

describe('POST /v1/translate', () => {
  const API_KEY = 'k'.repeat(40);
  const auth = { authorization: `Bearer ${API_KEY}` };
  let s: ReturnType<typeof setup>;
  let app: ReturnType<typeof buildApp>;

  beforeEach(() => {
    s = setup({ monthlyLimit: 40, warningLimit: 30 });
    app = buildApp({
      repo: new Repository(s.db, new SecretBox('c'.repeat(64))),
      apiKey: API_KEY,
      translation: s.service,
    });
  });

  const post = (payload: object, headers: Record<string, string> = auth) =>
    app.inject({ method: 'POST', url: '/v1/translate', headers, payload });

  const body = (over: object = {}) => ({
    userId: 'user-000001',
    messageId: '1',
    sourceLanguage: 'auto',
    targetLanguage: 'tr',
    subject: 'Hi',
    segments: ['Hello'],
    ...over,
  });

  it('kimlik doğrulaması ister', async () => {
    expect((await post(body(), {})).statusCode).toBe(401);
  });

  it('çevirir ve önbellek durumunu bildirir', async () => {
    const res = await post(body());
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ translatedSubject: 'tr:Hi', segments: ['tr:Hello'], cacheHit: false });
    expect((await post(body())).json().cacheHit).toBe(true);
  });

  it('limit dolunca 429 + iş hatası kodu', async () => {
    const res = await post(body({ segments: ['x'.repeat(50)] }));
    expect(res.statusCode).toBe(429);
    expect(res.json()).toEqual({ error: 'TRANSLATION_MONTHLY_LIMIT_REACHED' });
    expect(s.provider.calls).toHaveLength(0);
  });

  it('geçersiz istek 400', async () => {
    expect((await post(body({ targetLanguage: 'auto' }))).statusCode).toBe(400);
    expect((await post(body({ userId: 'x' }))).statusCode).toBe(400);
  });

  it('servis yoksa 503 TRANSLATION_UNAVAILABLE', async () => {
    const bare = buildApp({ repo: new Repository(s.db, new SecretBox('c'.repeat(64))), apiKey: API_KEY });
    const res = await bare.inject({ method: 'POST', url: '/v1/translate', headers: auth, payload: body() });
    expect(res.statusCode).toBe(503);
    expect(res.json()).toEqual({ error: 'TRANSLATION_UNAVAILABLE' });
  });
});

