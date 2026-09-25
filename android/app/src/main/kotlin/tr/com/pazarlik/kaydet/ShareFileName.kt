package tr.com.pazarlik.kaydet

/**
 * Paylaşımla gelen dosya adlarının güvenli hâle getirilmesi.
 *
 * Ad, paylaşan uygulamanın verdiği GÜVENİLMEYEN girdidir ve doğrudan dosya
 * sistemi yolu olarak kullanılmaz: yol ayırıcılar ve `..` atılır, kontrol
 * karakterleri ve Windows'ta geçersiz karakterler değiştirilir, uzunluk
 * sınırlanır. Sonuç HER ZAMAN tek bir yol bileşenidir. Dart tarafındaki
 * `SharedFile.isSafeFileName` ikinci savunma hattıdır.
 *
 * Android framework'üne bağlı değildir (MIME → uzantı eşlemesi dışarıdan
 * verilir) — böylece JVM birim testiyle doğrulanabilir.
 */
object ShareFileName {
    /** Gövde (uzantısız ad) için UTF-8 bayt sınırı; dosya sistemleri bileşen başına 255 bayt ister. */
    private const val MAX_BASE_BYTES = 120

    /** Uzantı için sınır; daha uzun "uzantılar" gerçekte uzantı değildir. */
    private const val MAX_EXTENSION_LENGTH = 16

    private const val FALLBACK_BASE = "ek"

    /** Windows'ta (alıcının bilgisayarı) geçersiz olan karakterler. */
    private val INVALID_CHARS = charArrayOf('<', '>', ':', '"', '|', '?', '*', '\\', '/')

    /**
     * @param raw paylaşan uygulamanın bildirdiği ad (boş/`null` olabilir).
     * @param extensionForMime adın uzantısı yoksa MIME türünden uzantı bulan işlev.
     */
    fun sanitize(
        raw: String?,
        mimeType: String?,
        extensionForMime: (String) -> String? = { null },
    ): String {
        // Yol bileşeni: son `/` ya da `\`ten sonrası (`../../etc/passwd` → `passwd`).
        var name = (raw ?: "").substringAfterLast('/').substringAfterLast('\\')

        name = buildString(name.length) {
            for (ch in name) {
                when {
                    ch.code < 0x20 || ch.code == 0x7f -> Unit // kontrol karakterleri atılır
                    ch in INVALID_CHARS -> append('_')
                    else -> append(ch)
                }
            }
        }
        // Baştaki nokta gizli dosya/`..` demek, sondaki nokta-boşluk Windows'ta geçersiz.
        name = name.trim().trim('.').trim()

        var base = name
        var extension = ""
        val dot = name.lastIndexOf('.')
        if (dot > 0 && name.length - dot - 1 in 1..MAX_EXTENSION_LENGTH &&
            name.substring(dot + 1).all { it.isLetterOrDigit() }
        ) {
            base = name.substring(0, dot).trim().trim('.')
            extension = name.substring(dot + 1)
        }

        if (base.isEmpty()) base = FALLBACK_BASE
        if (extension.isEmpty() && !mimeType.isNullOrBlank()) {
            extension = extensionForMime(mimeType)
                ?.takeIf { it.isNotEmpty() && it.length <= MAX_EXTENSION_LENGTH && it.all(Char::isLetterOrDigit) }
                ?: ""
        }

        base = truncateUtf8(base, MAX_BASE_BYTES).trimEnd().trimEnd('.')
        if (base.isEmpty()) base = FALLBACK_BASE

        return if (extension.isEmpty()) base else "$base.$extension"
    }

    /**
     * [desired] [taken] içinde varsa (büyük/küçük harf duyarsız) uzantıdan önce
     * ` (2)`, ` (3)`… ekler. Aynı paylaşımdaki iki `image.jpg` ayrı adlarla
     * kalır — alıcı da ayrı adlar görür.
     */
    fun unique(desired: String, taken: Set<String>): String {
        val lowered = taken.mapTo(HashSet()) { it.lowercase() }
        if (desired.lowercase() !in lowered) return desired

        val dot = desired.lastIndexOf('.')
        val base = if (dot > 0) desired.substring(0, dot) else desired
        val extension = if (dot > 0) desired.substring(dot) else ""
        var counter = 2
        while (true) {
            val candidate = "$base ($counter)$extension"
            if (candidate.lowercase() !in lowered) return candidate
            counter++
        }
    }

    /** Karakter (surrogate çifti) ortasından kesmeden en çok [maxBytes] UTF-8 baytına indirir. */
    private fun truncateUtf8(text: String, maxBytes: Int): String {
        var bytes = 0
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            val size = when {
                codePoint < 0x80 -> 1
                codePoint < 0x800 -> 2
                codePoint < 0x10000 -> 3
                else -> 4
            }
            if (bytes + size > maxBytes) break
            bytes += size
            index += Character.charCount(codePoint)
        }
        return text.substring(0, index)
    }
}
