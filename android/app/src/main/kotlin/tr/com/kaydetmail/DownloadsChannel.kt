package tr.com.kaydetmail

import android.annotation.TargetApi
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * Ek dosyalarını kullanıcının "İndirilenler" klasörüne DOĞRUDAN kaydeder
 * (Dart karşılığı: `DeviceDownloads`, kanal adı aynı).
 *
 * **Neden:** `file_saver`'ın `saveAs`'ı her dosya için ayrı bir Storage Access
 * Framework "kaydet" diyaloğu açar; çok ekli iletide N diyalog demek. Android
 * 10+ (API 29) `MediaStore.Downloads` ile uygulamanın İNDİRİLENLER'e yazması
 * için izin ya da diyalog GEREKTİRMEZ — Outlook'un "Kaydet" davranışı budur.
 *
 * API 29 altında bu yol yoktur (genel depolamaya yazmak çalışma zamanı izni
 * ister); `unsupported` hatası döner ve Dart tarafı dosya başına diyaloğa
 * geri düşer.
 */
class DownloadsChannel(context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL_NAME = "tr.com.kaydetmail/downloads"
        private const val TAG = "KaydetDownloads"
        private const val UNSAFE_NAME_CHARS = "[\\\\/:*?\"<>|\\p{Cntrl}]"
    }

    private val appContext = context.applicationContext
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "kaydet-downloads").apply { isDaemon = true }
    }
    private val mainHandler = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "saveToDownloads" -> saveToDownloads(call, result)
            "notifySaved" -> notifySaved(call, result)
            else -> result.notImplemented()
        }
    }

    private fun notifySaved(call: MethodCall, result: MethodChannel.Result) {
        val files = call.argument<List<Map<String, Any?>>>("files").orEmpty().mapNotNull { entry ->
            val uri = (entry["uri"] as? String)?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            SavedFile(
                uri = Uri.parse(uri),
                name = (entry["name"] as? String).orEmpty(),
                mimeType = (entry["mimeType"] as? String).orEmpty(),
            )
        }
        val folder = call.argument<String>("folder")
        // Bildirim yalnızca bilgidir: izin kapalıysa ya da gösterilemezse
        // sessizce vazgeçilir, kaydetme sonucunu asla bozmaz.
        try {
            SavedFilesNotifier.show(appContext, files, relativePath(folder))
        } catch (error: Throwable) {
            Log.w(TAG, "Bildirim gösterilemedi", error)
        }
        result.success(null)
    }

    private fun saveToDownloads(call: MethodCall, result: MethodChannel.Result) {
        val sourcePath = call.argument<String>("sourcePath")
        val fileName = call.argument<String>("fileName")
        if (sourcePath.isNullOrEmpty() || fileName.isNullOrEmpty()) {
            result.error("bad_args", "sourcePath ve fileName zorunlu", null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("unsupported", "API 29 altında doğrudan kaydetme yok", null)
            return
        }
        val mimeType = call.argument<String>("mimeType")
        val folder = call.argument<String>("folder")

        try {
            executor.execute {
                var written: SavedFile? = null
                val failure = try {
                    written = writeToDownloads(File(sourcePath), fileName, mimeType, folder)
                    null
                } catch (error: Throwable) {
                    Log.w(TAG, "Kaydedilemedi", error)
                    error
                }
                val saved = written
                mainHandler.post {
                    try {
                        if (failure == null && saved != null) {
                            result.success(
                                mapOf(
                                    "uri" to saved.uri.toString(),
                                    "name" to saved.name,
                                    "mimeType" to saved.mimeType,
                                ),
                            )
                        } else {
                            result.error("save_failed", failure?.message, null)
                        }
                    } catch (error: Throwable) {
                        // Motor kapanmış olabilir; dosya zaten yazıldı/geri alındı.
                        Log.w(TAG, "Sonuç iletilemedi", error)
                    }
                }
            }
        } catch (_: RejectedExecutionException) {
            result.error("save_failed", "Kanal kapalı", null)
        }
    }

    @TargetApi(Build.VERSION_CODES.Q)
    private fun writeToDownloads(source: File, fileName: String, mimeType: String?, folder: String?): SavedFile {
        if (!source.isFile) throw FileNotFoundException(source.path)

        val displayName = sanitize(fileName).ifEmpty { "dosya" }
        val resolvedMime = resolveMimeType(displayName, mimeType)
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, resolvedMime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath(folder))
            // Yazma bitene kadar dosya diğer uygulamalara (Dosyalar, Galeri) görünmez.
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }

        // Aynı adlı dosya varsa sistem adı kendisi "ad (1).uzantı" yapar; üzerine yazmaz.
        val resolver = appContext.contentResolver
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IOException("MediaStore kaydı oluşturulamadı")
        try {
            val output = resolver.openOutputStream(uri) ?: throw IOException("Çıkış akışı açılamadı")
            output.use { out -> source.inputStream().use { input -> input.copyTo(out) } }
            val done = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            resolver.update(uri, done, null, null)
            // Sistem aynı adlı dosya için "ad (1).uzantı" verdiyse bildirimde
            // GERÇEK ad görünsün.
            return SavedFile(uri, finalName(resolver, uri) ?: displayName, resolvedMime)
        } catch (error: Throwable) {
            // Yarım kalan dosya İndirilenler'de bozuk bir kayıt olarak kalmasın.
            try {
                resolver.delete(uri, null, null)
            } catch (_: Throwable) {
            }
            throw error
        }
    }

    private fun finalName(resolver: ContentResolver, uri: Uri): String? = try {
        resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    } catch (_: Throwable) {
        null
    }

    private fun sanitize(name: String): String =
        name.replace(Regex(UNSAFE_NAME_CHARS), "_").trim().trimEnd('.', ' ')

    /** `Download/Kaydet` gibi, sondaki eğik çizgisiz göreli yol. */
    private fun relativePath(folder: String?): String {
        val safeFolder = folder?.let { sanitize(it) }.orEmpty()
        return if (safeFolder.isEmpty()) {
            Environment.DIRECTORY_DOWNLOADS
        } else {
            "${Environment.DIRECTORY_DOWNLOADS}/$safeFolder"
        }
    }

    /**
     * Önce UZANTIDAN: gönderenin yazdığı tür sık sık yanlış/`octet-stream`'dir
     * ve MediaStore tür ile uzantı uyuşmazsa adın sonuna ikinci bir uzantı
     * ekleyebilir (`rapor.pdf.bin`). Uzantı bilinmiyorsa iletinin türü, o da
     * yoksa genel ikili tür kullanılır.
     */
    private fun resolveMimeType(displayName: String, provided: String?): String {
        val extension = displayName.substringAfterLast('.', "").lowercase()
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)?.let { return it }
        val cleaned = provided?.substringBefore(';')?.trim()?.lowercase().orEmpty()
        return if (cleaned.isNotEmpty() && cleaned.contains('/')) cleaned else "application/octet-stream"
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }
}
