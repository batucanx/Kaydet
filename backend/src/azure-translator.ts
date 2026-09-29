/** Algılanan dil (Azure `language` kodu: `en`, `de`, `zh-Hans`…). */
export interface DetectedLanguage {
  language: string;
  score: number;
}

/**
 * Çeviri sağlayıcısı arayüzü. Servis yalnızca bunu bilir; testler sahte bir
 * sağlayıcı verir, üretimde [AzureTranslatorProvider] kullanılır.
 */
export interface TranslateProvider {
  /** `texts` ile aynı sırada, aynı uzunlukta çeviri döner. */
  translate(texts: string[], target: string, source?: string): Promise<string[]>;
  /** Metnin dilini algılar. */
  detect(text: string): Promise<DetectedLanguage>;
}

/**
 * Sağlayıcı çağrısı başarısız oldu.
 *
 * `definitelyNotProcessed`: istek Azure tarafından kesin olarak işlenmedi
 * (ör. 400/401/403/429 yanıtı) — ayrılan kota güvenle iade edilir. `false` ise
 * sonuç belirsizdir (zaman aşımı, bağlantı kopması: Azure isteği işleyip
 * sayaca yazmış olabilir) ve karakterler harcanmış sayılır.
 */
export class TranslateProviderError extends Error {
  constructor(
    message: string,
    readonly definitelyNotProcessed: boolean,
    /** Azure'un HTTP durumu (varsa) — yalnızca logda anlamlı, içerik taşımaz. */
    readonly status?: number,
  ) {
    super(message);
    this.name = 'TranslateProviderError';
  }
}

export interface AzureTranslatorOptions {
  /** Global: `https://api.cognitive.microsofttranslator.com`. Özel alan adlı
   *  kaynak: `https://<ad>.cognitiveservices.azure.com`. */
  endpoint: string;
  key: string;
  /** Bölgesel/çok hizmetli kaynaklarda zorunlu; global tek hizmetli kaynakta boş olabilir. */
  region?: string;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
}

/**
 * Azure AI Translator — Text Translation REST API v3.0. Anahtar yalnızca sunucu
 * ortamında durur ve URL'ye değil başlığa konur (URL'ler loglanabilir).
 * Ek bağımlılık yok: Node'un yerleşik `fetch`i.
 */
export class AzureTranslatorProvider implements TranslateProvider {
  private readonly base: URL;
  private readonly timeoutMs: number;
  private readonly fetchImpl: typeof fetch;

  constructor(private readonly opts: AzureTranslatorOptions) {
    this.base = new URL(opts.endpoint);
    if (this.base.protocol !== 'https:') {
      throw new Error('AZURE_TRANSLATOR_ENDPOINT https olmalı');
    }
    this.timeoutMs = opts.timeoutMs ?? 15_000;
    this.fetchImpl = opts.fetchImpl ?? fetch;
  }

  async translate(texts: string[], target: string, source?: string): Promise<string[]> {
    if (texts.length === 0) return [];
    const query = new URLSearchParams({ 'api-version': '3.0', to: target, textType: 'plain' });
    if (source) query.set('from', source);
    const parsed = await this.post('translate', query, texts);
    if (!Array.isArray(parsed) || parsed.length !== texts.length) {
      throw new TranslateProviderError('Azure yanıtı beklenmedik biçimde', false);
    }
    return parsed.map((item) => {
      const text = (item as { translations?: { text?: unknown }[] })?.translations?.[0]?.text;
      if (typeof text !== 'string') {
        throw new TranslateProviderError('Azure yanıtı beklenmedik biçimde', false);
      }
      return text;
    });
  }

  async detect(text: string): Promise<DetectedLanguage> {
    const parsed = await this.post('detect', new URLSearchParams({ 'api-version': '3.0' }), [text]);
    const first = Array.isArray(parsed) ? (parsed[0] as Partial<DetectedLanguage>) : undefined;
    if (!first || typeof first.language !== 'string') {
      throw new TranslateProviderError('Azure yanıtı beklenmedik biçimde', false);
    }
    return { language: first.language, score: typeof first.score === 'number' ? first.score : 0 };
  }

  private url(operation: 'translate' | 'detect', query: URLSearchParams): string {
    // Global uç noktada yol `/translate`, özel alan adlı kaynakta
    // `/translator/text/v3.0/translate`.
    const global = this.base.hostname.endsWith('.microsofttranslator.com');
    const path = global ? `/${operation}` : `/translator/text/v3.0/${operation}`;
    return `${this.base.origin}${path}?${query.toString()}`;
  }

  private async post(
    operation: 'translate' | 'detect',
    query: URLSearchParams,
    texts: string[],
  ): Promise<unknown> {
    const headers: Record<string, string> = {
      'content-type': 'application/json; charset=UTF-8',
      'ocp-apim-subscription-key': this.opts.key,
    };
    if (this.opts.region) headers['ocp-apim-subscription-region'] = this.opts.region;

    let res: Response;
    try {
      res = await this.fetchImpl(this.url(operation, query), {
        method: 'POST',
        headers,
        body: JSON.stringify(texts.map((Text) => ({ Text }))),
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch {
      // İstek gitmiş olabilir; yanıt gelmedi (ağ hatası ya da zaman aşımı).
      throw new TranslateProviderError('Azure isteği tamamlanamadı', false);
    }
    if (!res.ok) {
      // Hata gövdesi loglanmaz/aktarılmaz (istek metnini yansıtabilir).
      throw new TranslateProviderError(`Azure HTTP ${res.status}`, true, res.status);
    }
    try {
      return await res.json();
    } catch {
      throw new TranslateProviderError('Azure yanıtı okunamadı', false);
    }
  }
}
