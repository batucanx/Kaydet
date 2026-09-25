package tr.com.pazarlik.kaydet

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.util.Log
import android.webkit.MimeTypeMap
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.util.UUID

/**
 * `ACTION_SEND` / `ACTION_SEND_MULTIPLE` Intent'ini [ShareInbox]'a çevirir.
 *
 * `content://` URI'leri ASLA dosya yolu sanılmaz: her biri `ContentResolver`
 * üzerinden okunup uygulamanın kendi dizinine kopyalanır. Hiçbir hata uygulamayı
 * çökertmez — okunamayan/çok büyük/boş dosya paylaşımın `issues` listesine
 * yazılır ve Flutter kullanıcıya anlaşılır bir mesaj gösterir.
 *
 * Bloklayıcıdır (dosya G/Ç); ana iş parçacığında ÇAĞRILMAMALI (bkz.
 * [ShareChannel]).
 */
class ShareIntake(context: Context, private val inbox: ShareInbox) {
    private val resolver: ContentResolver = context.applicationContext.contentResolver

    companion object {
        private const val TAG = "KaydetShare"
        private const val SOURCE = "android-share"

        /** Tek paylaşımda işlenecek en çok dosya; kötü niyetli uygulamanın binlerce URI göndermesini önler. */
        private const val MAX_FILES = 50

        /** Gövdeye konacak metin için üst sınır. */
        private const val MAX_TEXT_LENGTH = 50_000

        private const val BUFFER_SIZE = 64 * 1024

        fun isShareIntent(intent: Intent?): Boolean =
            intent?.action == Intent.ACTION_SEND || intent?.action == Intent.ACTION_SEND_MULTIPLE
    }

    /** Bir dosyanın kopyalanma sonucu. */
    private sealed interface CopyOutcome {
        class Copied(val fileName: String, val mimeType: String, val sizeBytes: Long) : CopyOutcome
        class Rejected(val code: String, val fileName: String?) : CopyOutcome
    }

    /**
     * Paylaşımı işler ve manifesti yazar. Paylaşım kimliğini döndürür; kimlik
     * ancak manifest diske yazıldıktan sonra "bekleyen" olur. Manifest bile
     * yazılamadıysa `null`.
     */
    fun process(intent: Intent): String? {
        val id = UUID.randomUUID().toString()
        return try {
            val directory = inbox.createPayloadDirectory(id)
            inbox.writeManifest(id, buildManifest(id, directory, intent))
            id
        } catch (error: Throwable) {
            // Beklenmeyen hata (disk dolu, çalışma zamanı hatası…): kısmi kopyayı
            // sil ve kullanıcıya bir hata göstermek için hata manifesti yaz.
            Log.e(TAG, "Paylaşım işlenemedi", error)
            inbox.discard(id)
            writeFailureManifest(id)
        }
    }

    private fun writeFailureManifest(id: String): String? = try {
        inbox.createPayloadDirectory(id)
        inbox.writeManifest(
            id,
            JSONObject()
                .put("version", 1)
                .put("id", id)
                .put("source", SOURCE)
                .put("receivedAtMs", System.currentTimeMillis())
                .put("files", JSONArray())
                .put("issues", JSONArray().put(JSONObject().put("code", "storage"))),
        )
        id
    } catch (error: Throwable) {
        Log.e(TAG, "Hata manifesti yazılamadı", error)
        null
    }

    private fun buildManifest(id: String, directory: File, intent: Intent): JSONObject {
        val uris = extractUris(intent)
        val files = JSONArray()
        val issues = JSONArray()
        val takenNames = HashSet<String>()
        var totalBytes = 0L

        for ((index, uri) in uris.withIndex()) {
            if (index >= MAX_FILES) {
                issues.put(JSONObject().put("code", "unknown"))
                break
            }
            when (val outcome = copyOne(uri, directory, intent.type, takenNames, totalBytes)) {
                is CopyOutcome.Copied -> {
                    takenNames.add(outcome.fileName)
                    totalBytes += outcome.sizeBytes
                    files.put(
                        JSONObject()
                            .put("fileName", outcome.fileName)
                            .put("mimeType", outcome.mimeType)
                            .put("sizeBytes", outcome.sizeBytes),
                    )
                }
                is CopyOutcome.Rejected -> issues.put(
                    JSONObject().put("code", outcome.code).apply {
                        outcome.fileName?.let { put("fileName", it) }
                    },
                )
            }
        }

        val manifest = JSONObject()
            .put("version", 1)
            .put("id", id)
            .put("source", SOURCE)
            .put("receivedAtMs", System.currentTimeMillis())
            .put("files", files)
            .put("issues", issues)

        readText(intent, Intent.EXTRA_TEXT)?.let { manifest.put("text", it.take(MAX_TEXT_LENGTH)) }
        readText(intent, Intent.EXTRA_SUBJECT)?.let { manifest.put("subject", it.take(998)) }
        return manifest
    }

    /**
     * `EXTRA_STREAM` (tek ya da liste) ve `ClipData` içindeki URI'ler; paylaşım
     * SIRASI korunur, tekrarlar atılır. Bozuk/beklenmeyen tür taşıyan extra
     * yalnızca yok sayılır.
     */
    @Suppress("DEPRECATION")
    private fun extractUris(intent: Intent): List<Uri> {
        val uris = LinkedHashSet<Uri>()
        try {
            when (intent.action) {
                Intent.ACTION_SEND -> {
                    val single = if (Build.VERSION.SDK_INT >= 33) {
                        intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                    } else {
                        intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                    }
                    single?.let(uris::add)
                }
                Intent.ACTION_SEND_MULTIPLE -> {
                    val list = if (Build.VERSION.SDK_INT >= 33) {
                        intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                    } else {
                        intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                    }
                    list?.filterNotNull()?.let(uris::addAll)
                }
            }
        } catch (error: Throwable) {
            Log.w(TAG, "EXTRA_STREAM okunamadı", error)
        }

        // Bazı uygulamalar URI'yi yalnızca ClipData'ya koyar (Android 10+ ikisini de doldurur).
        try {
            val clip = intent.clipData
            if (clip != null) {
                for (i in 0 until clip.itemCount) {
                    clip.getItemAt(i).uri?.let(uris::add)
                }
            }
        } catch (error: Throwable) {
            Log.w(TAG, "ClipData okunamadı", error)
        }
        return uris.toList()
    }

    private fun readText(intent: Intent, key: String): String? = try {
        intent.getCharSequenceExtra(key)?.toString()?.takeIf { it.isNotBlank() }
    } catch (error: Throwable) {
        Log.w(TAG, "$key okunamadı", error)
        null
    }

    private fun copyOne(
        uri: Uri,
        directory: File,
        intentType: String?,
        takenNames: Set<String>,
        totalSoFar: Long,
    ): CopyOutcome {
        // `file://` yalnızca uygulamanın KENDİ özel dizinlerini (veritabanı,
        // kimlik bilgileri) okutmaya yarayabilir; `content://` dışındaki her
        // şema reddedilir.
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) {
            return CopyOutcome.Rejected("unreadable", null)
        }

        val (displayName, declaredSize) = queryMetadata(uri)
        val mimeType = resolveMimeType(uri, displayName, intentType)
        val fileName = ShareFileName.unique(
            ShareFileName.sanitize(displayName ?: uri.lastPathSegment, mimeType) { mime ->
                MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
            },
            takenNames,
        )

        // Boyut önceden biliniyorsa hiç kopyalamaya başlanmaz.
        if (declaredSize > ShareInbox.MAX_FILE_BYTES ||
            (declaredSize > 0 && totalSoFar + declaredSize > ShareInbox.MAX_TOTAL_BYTES)
        ) {
            return CopyOutcome.Rejected("tooLarge", fileName)
        }

        val target = File(directory, fileName)
        // Ad zaten temizlendi; yine de hedefin gerçekten paylaşım dizininde
        // kaldığı doğrulanır.
        if (target.canonicalFile.parentFile != directory.canonicalFile) {
            return CopyOutcome.Rejected("unreadable", fileName)
        }

        val remainingTotal = ShareInbox.MAX_TOTAL_BYTES - totalSoFar
        val limit = minOf(ShareInbox.MAX_FILE_BYTES, remainingTotal)
        return try {
            val stream = resolver.openInputStream(uri)
                ?: return CopyOutcome.Rejected("unreadable", fileName)
            val written = stream.use { input ->
                target.outputStream().use { output -> copyLimited(input, output, limit) }
            }
            when {
                written < 0 -> {
                    target.delete()
                    CopyOutcome.Rejected("tooLarge", fileName)
                }
                written == 0L -> {
                    target.delete()
                    CopyOutcome.Rejected("empty", fileName)
                }
                else -> CopyOutcome.Copied(fileName, mimeType, written)
            }
        } catch (error: SecurityException) {
            // Paylaşan uygulama URI izni vermemiş/iznini geri almış.
            Log.w(TAG, "URI izni yok", error)
            target.delete()
            CopyOutcome.Rejected("unreadable", fileName)
        } catch (error: FileNotFoundException) {
            target.delete()
            CopyOutcome.Rejected("unreadable", fileName)
        } catch (error: IOException) {
            // Kaynak okunamadı ya da hedef yazılamadı (yer yok…).
            Log.w(TAG, "Dosya kopyalanamadı", error)
            target.delete()
            CopyOutcome.Rejected("storage", fileName)
        } catch (error: RuntimeException) {
            // Bozuk URI, desteklenmeyen sağlayıcı işlemi vb.: çökmek yerine reddet.
            Log.w(TAG, "Dosya okunamadı", error)
            target.delete()
            CopyOutcome.Rejected("unreadable", fileName)
        }
    }

    /**
     * En çok [limit] bayt kopyalar. Sınır aşılırsa `-1` döner (çağıran kısmi
     * dosyayı siler). Bildirilen boyuta güvenilmez: kaynak yalan söyleyebilir.
     */
    private fun copyLimited(
        input: java.io.InputStream,
        output: java.io.OutputStream,
        limit: Long,
    ): Long {
        val buffer = ByteArray(BUFFER_SIZE)
        var total = 0L
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            total += read
            if (total > limit) return -1
            output.write(buffer, 0, read)
        }
        return total
    }

    /** `DISPLAY_NAME` ve `SIZE`; sağlayıcı sorguyu desteklemiyorsa `(null, -1)`. */
    private fun queryMetadata(uri: Uri): Pair<String?, Long> = try {
        resolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null,
        )?.use { cursor ->
            if (!cursor.moveToFirst()) return@use Pair(null, -1L)
            val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
            val name = if (nameIndex >= 0 && !cursor.isNull(nameIndex)) cursor.getString(nameIndex) else null
            val size = if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) cursor.getLong(sizeIndex) else -1L
            Pair(name, size)
        } ?: Pair(null, -1L)
    } catch (error: Throwable) {
        Log.w(TAG, "Dosya bilgisi alınamadı", error)
        Pair(null, -1L)
    }

    /** Sağlayıcının türü → Intent türü (yalnızca joker değilse) → uzantıdan → genel ikili. */
    private fun resolveMimeType(uri: Uri, displayName: String?, intentType: String?): String {
        val fromProvider = try {
            resolver.getType(uri)
        } catch (error: Throwable) {
            null
        }
        val candidates = listOf(
            fromProvider,
            intentType,
            displayName?.substringAfterLast('.', "")?.lowercase()?.takeIf { it.isNotEmpty() }
                ?.let { MimeTypeMap.getSingleton().getMimeTypeFromExtension(it) },
        )
        return candidates
            .firstOrNull { !it.isNullOrBlank() && !it.contains('*') }
            ?.lowercase()
            ?: "application/octet-stream"
    }
}
