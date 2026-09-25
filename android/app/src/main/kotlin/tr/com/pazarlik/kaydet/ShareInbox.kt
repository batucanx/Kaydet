package tr.com.pazarlik.kaydet

import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.io.IOException

/**
 * Sistem "Paylaş" menüsünden gelen dosyaların kalıcı gelen kutusu:
 * `filesDir/share_inbox/<id>/<dosya adı>` + `manifest.json`.
 *
 * `cacheDir` DEĞİL `filesDir`: sistem cache'i düşük depolamada istediği an
 * temizleyebilir, oysa dosyalar bir taslağın eki olarak günlerce bekleyebilir
 * ve gönderim anında okunur (bkz. `SmtpService`, eksik dosyayı sessizce atlar).
 * Uygulama içi dizin olduğu için başka uygulamalar okuyamaz.
 *
 * **Tüketilmiş durumu:** manifestin varlığı "henüz teslim edilmedi" demektir;
 * Flutter [acknowledge] ile manifesti siler (dosyalar kalır — artık taslağın
 * eki). Manifest, dosyalar kopyalandıktan SONRA ve atomik (yaz → yeniden
 * adlandır) yazılır; yarım kalmış bir kopya asla "bekleyen paylaşım" olarak
 * görünmez.
 *
 * Flutter tarafındaki karşılıkları: `SharePayload`, `ShareIntakeService`. Sınır
 * sabitleri `ShareAttachmentPolicy` ile AYNI olmalı.
 */
class ShareInbox(val root: File) {
    companion object {
        const val DIRECTORY_NAME = "share_inbox"
        const val MANIFEST_NAME = "manifest.json"
        private const val MANIFEST_TMP_NAME = "manifest.json.tmp"

        /** Bkz. `ShareAttachmentPolicy.maxFileBytes`. */
        const val MAX_FILE_BYTES = 25L * 1024 * 1024

        /** Bkz. `ShareAttachmentPolicy.maxTotalBytes`. */
        const val MAX_TOTAL_BYTES = 50L * 1024 * 1024

        /** Kimlik dizin adı olarak kullanılır; bkz. `SharePayload.isValidId`. */
        private val ID_PATTERN = Regex("^[A-Za-z0-9-]{8,64}$")

        fun isValidId(id: String?): Boolean = id != null && ID_PATTERN.matches(id)
    }

    /** Paylaşıma ait dizini oluşturur. [id] geçersizse istisna fırlatır. */
    fun createPayloadDirectory(id: String): File {
        require(isValidId(id)) { "Geçersiz paylaşım kimliği" }
        val directory = File(root, id)
        if (!directory.isDirectory && !directory.mkdirs()) {
            throw IOException("Paylaşım dizini oluşturulamadı")
        }
        return directory
    }

    /** Manifesti atomik olarak yazar; bu andan itibaren paylaşım "bekleyen"dir. */
    fun writeManifest(id: String, manifest: JSONObject) {
        require(isValidId(id)) { "Geçersiz paylaşım kimliği" }
        val directory = File(root, id)
        val temp = File(directory, MANIFEST_TMP_NAME)
        temp.writeText(manifest.toString(), Charsets.UTF_8)
        val target = File(directory, MANIFEST_NAME)
        if (!temp.renameTo(target)) {
            temp.delete()
            throw IOException("Manifest yazılamadı")
        }
    }

    /**
     * Tüketilmemiş paylaşımların manifest metinleri, en eskiden yeniye.
     * Bozuk manifestler ve dizin adıyla `id`si uyuşmayanlar atlanır.
     */
    fun readPending(): List<String> {
        val directories = root.listFiles { file -> file.isDirectory && isValidId(file.name) }
            ?: return emptyList()

        return directories
            .mapNotNull { directory ->
                val manifest = File(directory, MANIFEST_NAME)
                if (!manifest.isFile) return@mapNotNull null
                try {
                    val text = manifest.readText(Charsets.UTF_8)
                    val json = JSONObject(text)
                    if (json.optString("id") != directory.name) return@mapNotNull null
                    Pair(json.optLong("receivedAtMs", manifest.lastModified()), text)
                } catch (_: IOException) {
                    null
                } catch (_: JSONException) {
                    null
                }
            }
            .sortedBy { it.first }
            .map { it.second }
    }

    /** Tüketildi: manifesti siler, dosyalar kalır. Kimlik geçersizse yok sayılır. */
    fun acknowledge(id: String?) {
        if (!isValidId(id)) return
        File(File(root, id!!), MANIFEST_NAME).delete()
    }

    /** Paylaşımı dosyalarıyla birlikte siler. Kimlik geçersizse yok sayılır. */
    fun discard(id: String?) {
        if (!isValidId(id)) return
        File(root, id!!).deleteRecursively()
    }
}
