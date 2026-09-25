package tr.com.pazarlik.kaydet

import android.content.ClipData
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import java.io.File
import java.io.RandomAccessFile

/**
 * `ShareIntake`in gerçek `ContentResolver` üzerinden davranışı: Robolectric ile
 * sahte bir `ContentProvider` (Galeri/Dosyalar'ın rolünde) kurulur.
 */
@RunWith(RobolectricTestRunner::class)
class ShareIntakeTest {
    private lateinit var context: Context
    private lateinit var root: File
    private lateinit var inbox: ShareInbox
    private lateinit var intake: ShareIntake

    /** Sahte sağlayıcının sunduğu bir "dosya". */
    class Entry(
        val displayName: String?,
        /** `OpenableColumns.SIZE`; `null` ise sütun boş (sağlayıcı boyut bilmiyor / yalan söylüyor). */
        val declaredSize: Long?,
        val mime: String?,
        val file: File?,
        val failOpen: RuntimeException? = null,
    )

    class FakeProvider : ContentProvider() {
        companion object {
            const val AUTHORITY = "kaydet.test.provider"
            val entries = HashMap<String, Entry>()
        }

        override fun onCreate() = true

        override fun query(
            uri: Uri,
            projection: Array<out String>?,
            selection: String?,
            selectionArgs: Array<out String>?,
            sortOrder: String?,
        ): Cursor? {
            val entry = entries[uri.lastPathSegment] ?: return null
            return MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)).apply {
                addRow(arrayOf<Any?>(entry.displayName, entry.declaredSize))
            }
        }

        override fun getType(uri: Uri): String? = entries[uri.lastPathSegment]?.mime

        override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
            val entry = entries[uri.lastPathSegment] ?: return null
            entry.failOpen?.let { throw it }
            return ParcelFileDescriptor.open(entry.file, ParcelFileDescriptor.MODE_READ_ONLY)
        }

        override fun insert(uri: Uri, values: ContentValues?): Uri? = null
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
        override fun update(
            uri: Uri,
            values: ContentValues?,
            selection: String?,
            selectionArgs: Array<out String>?,
        ) = 0
    }

    private val sources = mutableListOf<File>()

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        root = File(context.cacheDir, "inbox_${System.nanoTime()}")
        inbox = ShareInbox(root)
        intake = ShareIntake(context, inbox)
        FakeProvider.entries.clear()
        Robolectric.setupContentProvider(FakeProvider::class.java, FakeProvider.AUTHORITY)
    }

    @After
    fun tearDown() {
        root.deleteRecursively()
        sources.forEach { it.delete() }
    }

    /** Sağlayıcıya bir dosya ekler ve `content://` URI'sini döndürür. */
    private fun provide(
        key: String,
        content: ByteArray = byteArrayOf(1, 2, 3),
        displayName: String? = key,
        declaredSize: Long? = content.size.toLong(),
        mime: String? = null,
        failOpen: RuntimeException? = null,
    ): Uri {
        val file = File.createTempFile("src_", ".bin").also { sources.add(it) }
        file.writeBytes(content)
        FakeProvider.entries[key] = Entry(displayName, declaredSize, mime, file, failOpen)
        return Uri.parse("content://${FakeProvider.AUTHORITY}/$key")
    }

    /** Sağlayıcıda diskte yer tutmayan (seyrek) [size] baytlık dosya. */
    private fun provideSparse(key: String, size: Long, declaredSize: Long? = size, name: String = key): Uri {
        val uri = provide(key, byteArrayOf(0), name, declaredSize)
        RandomAccessFile(FakeProvider.entries[key]!!.file!!, "rw").use { it.setLength(size) }
        return uri
    }

    private fun send(vararg uris: Uri, type: String = "*/*"): Intent =
        if (uris.size == 1) {
            Intent(Intent.ACTION_SEND).setType(type).putExtra(Intent.EXTRA_STREAM, uris[0])
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE).setType(type)
                .putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris.toList()))
        }

    /** İşler ve tek bekleyen manifesti döndürür. */
    private fun run(intent: Intent): JSONObject {
        val id = intake.process(intent)
        assertNotNull("manifest yazılmalı", id)
        val pending = inbox.readPending()
        assertEquals(1, pending.size)
        val manifest = JSONObject(pending.single())
        assertEquals(id, manifest.getString("id"))
        return manifest
    }

    private fun fileNames(manifest: JSONObject) =
        (0 until manifest.getJSONArray("files").length()).map {
            manifest.getJSONArray("files").getJSONObject(it).getString("fileName")
        }

    private fun issueCodes(manifest: JSONObject) =
        (0 until manifest.getJSONArray("issues").length()).map {
            manifest.getJSONArray("issues").getJSONObject(it).getString("code")
        }

    private fun stored(manifest: JSONObject, name: String) = File(File(root, manifest.getString("id")), name)

    @Test
    fun `tek fotograf adi, turu ve icerigiyle kopyalanir`() {
        val uri = provide("1", byteArrayOf(9, 8, 7, 6), "IMG_0001.jpg", mime = "image/jpeg")

        val manifest = run(send(uri, type = "image/*"))

        assertEquals(listOf("IMG_0001.jpg"), fileNames(manifest))
        val entry = manifest.getJSONArray("files").getJSONObject(0)
        assertEquals("image/jpeg", entry.getString("mimeType"))
        assertEquals(4L, entry.getLong("sizeBytes"))
        assertEquals("android-share", manifest.getString("source"))
        assertEquals(listOf(9, 8, 7, 6), stored(manifest, "IMG_0001.jpg").readBytes().map { it.toInt() })
        assertEquals(emptyList<String>(), issueCodes(manifest))
    }

    @Test
    fun `birden cok dosyada paylasim sirasi korunur, ayni adlar numaralanir`() {
        val uris = arrayOf(
            provide("a", displayName = "foto.jpg", mime = "image/jpeg"),
            provide("b", displayName = "belge.pdf", mime = "application/pdf"),
            provide("c", displayName = "foto.jpg", mime = "image/jpeg"),
            provide("d", displayName = "Ozet.txt", mime = "text/plain"),
        )

        val manifest = run(send(*uris))

        assertEquals(listOf("foto.jpg", "belge.pdf", "foto (2).jpg", "Ozet.txt"), fileNames(manifest))
        fileNames(manifest).forEach { assertTrue(it, stored(manifest, it).isFile) }
    }

    @Test
    fun `yalniz ClipData ile gelen URI de alinir, EXTRA_STREAM ile tekrar edilmez`() {
        val uri = provide("1", displayName = "klip.png", mime = "image/png")

        val onlyClip = Intent(Intent.ACTION_SEND).setType("image/*")
            .apply { clipData = ClipData.newRawUri("dosya", uri) }
        assertEquals(listOf("klip.png"), fileNames(run(onlyClip)))
    }

    @Test
    fun `ayni URI hem EXTRA_STREAM hem ClipData icinde ise bir kez eklenir`() {
        val uri = provide("1", displayName = "tek.png", mime = "image/png")

        val intent = send(uri, type = "image/*").apply { clipData = ClipData.newRawUri("x", uri) }

        assertEquals(listOf("tek.png"), fileNames(run(intent)))
    }

    @Test
    fun `duz metin paylasimi dosya olmadan metin ve konu tasir`() {
        val intent = Intent(Intent.ACTION_SEND).setType("text/plain")
            .putExtra(Intent.EXTRA_TEXT, "https://ornek.com/yazi")
            .putExtra(Intent.EXTRA_SUBJECT, "Güzel bir yazı")

        val manifest = run(intent)

        assertEquals("https://ornek.com/yazi", manifest.getString("text"))
        assertEquals("Güzel bir yazı", manifest.getString("subject"))
        assertEquals(emptyList<String>(), fileNames(manifest))
        assertEquals(emptyList<String>(), issueCodes(manifest))
    }

    @Test
    fun `bos paylasim (null URI, metin yok) coker degil bos manifest yazar`() {
        val manifest = run(Intent(Intent.ACTION_SEND).setType("image/*"))

        assertEquals(emptyList<String>(), fileNames(manifest))
        assertFalse(manifest.has("text"))
    }

    @Test
    fun `null MIME ve joker tur genel ikiliye, uzanti varsa uzantidan cozulur`() {
        val unknown = provide("1", displayName = "veri", mime = null)
        val pdf = provide("2", displayName = "rapor.pdf", mime = null)

        val manifest = run(send(unknown, pdf, type = "*/*"))

        val files = manifest.getJSONArray("files")
        assertEquals("application/octet-stream", files.getJSONObject(0).getString("mimeType"))
        assertEquals("application/pdf", files.getJSONObject(1).getString("mimeType"))
    }

    @Test
    fun `uzantisiz ad MIME turunden uzanti alir`() {
        val uri = provide("1", displayName = "foto", mime = "image/jpeg")

        assertEquals(listOf("foto.jpg"), fileNames(run(send(uri))))
    }

    @Test
    fun `saglayici ad vermezse URI son bolumu kullanilir`() {
        val uri = provide("kamera123", displayName = null, mime = "image/jpeg")

        assertEquals(listOf("kamera123.jpg"), fileNames(run(send(uri))))
    }

    @Test
    fun `dusmanca ad paylasim dizininin disina cikamaz`() {
        val uri = provide("1", displayName = "../../../evil.jpg", mime = "image/jpeg")

        val manifest = run(send(uri))

        assertEquals(listOf("evil.jpg"), fileNames(manifest))
        val dir = File(root, manifest.getString("id"))
        assertEquals(dir.canonicalFile, stored(manifest, "evil.jpg").canonicalFile.parentFile)
        assertFalse(File(root.parentFile, "evil.jpg").exists())
        assertFalse(File(root, "evil.jpg").exists())
    }

    @Test
    fun `bildirilen boyutu sinirdan buyuk dosya hic kopyalanmaz`() {
        val big = provideSparse("big", ShareInbox.MAX_FILE_BYTES + 1, name = "film.mov")
        val ok = provide("ok", displayName = "iyi.jpg", mime = "image/jpeg")

        val manifest = run(send(big, ok))

        assertEquals(listOf("iyi.jpg"), fileNames(manifest))
        assertEquals(listOf("tooLarge"), issueCodes(manifest))
        assertFalse(stored(manifest, "film.mov").exists())
        assertEquals(
            "film.mov",
            manifest.getJSONArray("issues").getJSONObject(0).getString("fileName"),
        )
    }

    @Test
    fun `saglayici boyut konusunda yalan soylerse kopya sirasinda kesilir ve kismi dosya silinir`() {
        // Boyut bilinmiyor (null) ama gerçekte sınırı aşıyor.
        val liar = provideSparse("liar", ShareInbox.MAX_FILE_BYTES + 4096, declaredSize = null, name = "gizli.bin")

        val manifest = run(send(liar))

        assertEquals(emptyList<String>(), fileNames(manifest))
        assertEquals(listOf("tooLarge"), issueCodes(manifest))
        assertFalse("kısmi dosya kalmamalı", stored(manifest, "gizli.bin").exists())
    }

    @Test
    fun `tam sinirdaki dosya kabul edilir`() {
        val exact = provideSparse("exact", ShareInbox.MAX_FILE_BYTES, name = "tam.bin")

        assertEquals(listOf("tam.bin"), fileNames(run(send(exact))))
    }

    @Test
    fun `toplam sinir asilirsa sondaki dosyalar reddedilir`() {
        val size = 20L * 1024 * 1024
        val uris = arrayOf(
            provideSparse("1", size, name = "1.bin"),
            provideSparse("2", size, name = "2.bin"),
            provideSparse("3", size, name = "3.bin"),
        )

        val manifest = run(send(*uris))

        // 20 + 20 = 40 MB sığar; üçüncüsü 50 MB'ı aşar.
        assertEquals(listOf("1.bin", "2.bin"), fileNames(manifest))
        assertEquals(listOf("tooLarge"), issueCodes(manifest))
    }

    @Test
    fun `bos dosya reddedilir`() {
        val empty = provide("1", content = ByteArray(0), displayName = "bos.txt", declaredSize = 0)

        val manifest = run(send(empty))

        assertEquals(emptyList<String>(), fileNames(manifest))
        assertEquals(listOf("empty"), issueCodes(manifest))
        assertFalse(stored(manifest, "bos.txt").exists())
    }

    @Test
    fun `URI izni yoksa coker degil reddeder, diger dosyalar yine eklenir`() {
        val denied = provide("1", displayName = "izinsiz.jpg", failOpen = SecurityException("izin yok"))
        val ok = provide("2", displayName = "iyi.jpg", mime = "image/jpeg")

        val manifest = run(send(denied, ok))

        assertEquals(listOf("iyi.jpg"), fileNames(manifest))
        assertEquals(listOf("unreadable"), issueCodes(manifest))
        assertFalse(stored(manifest, "izinsiz.jpg").exists())
    }

    @Test
    fun `okunamayan ve bulunamayan URI cokmez`() {
        val missing = Uri.parse("content://${FakeProvider.AUTHORITY}/yok")
        val broken = provide("2", displayName = "bozuk.jpg", failOpen = IllegalStateException("sağlayıcı bozuk"))

        val manifest = run(send(missing, broken))

        assertEquals(emptyList<String>(), fileNames(manifest))
        assertEquals(listOf("unreadable", "unreadable"), issueCodes(manifest))
    }

    @Test
    fun `file semali URI reddedilir ve okunmaz`() {
        val secret = File.createTempFile("gizli_", ".db").also {
            sources.add(it)
            it.writeText("uygulama verisi")
        }

        val manifest = run(send(Uri.fromFile(secret)))

        assertEquals(emptyList<String>(), fileNames(manifest))
        assertEquals(listOf("unreadable"), issueCodes(manifest))
        val dir = File(root, manifest.getString("id"))
        assertEquals(listOf("manifest.json"), dir.list()!!.toList())
    }

    @Test
    fun `dosya sayisi ustsinirinda ek dosyalar atilir`() {
        val uris = (1..52).map { provide("f$it", displayName = "f$it.txt", mime = "text/plain") }.toTypedArray()

        val manifest = run(send(*uris))

        assertEquals(50, fileNames(manifest).size)
        assertEquals(listOf("unknown"), issueCodes(manifest))
        // Sıra korunur.
        assertEquals("f1.txt", fileNames(manifest).first())
        assertEquals("f50.txt", fileNames(manifest).last())
    }

    @Test
    fun `her paylasim ayri kimlik alir ve birbirini bozmaz`() {
        val first = intake.process(send(provide("1", displayName = "a.jpg", mime = "image/jpeg")))
        val second = intake.process(send(provide("2", displayName = "a.jpg", mime = "image/jpeg")))

        assertNotNull(first)
        assertNotNull(second)
        assertTrue(first != second)
        assertEquals(2, inbox.readPending().size)
        // Aynı ad, ayrı dizinlerde: numaralanmaz.
        assertTrue(File(root, "$first/a.jpg").isFile)
        assertTrue(File(root, "$second/a.jpg").isFile)
    }

    @Test
    fun `paylasim Intent'i olmayan Intent tanınmaz`() {
        assertTrue(ShareIntake.isShareIntent(Intent(Intent.ACTION_SEND)))
        assertTrue(ShareIntake.isShareIntent(Intent(Intent.ACTION_SEND_MULTIPLE)))
        assertFalse(ShareIntake.isShareIntent(Intent(Intent.ACTION_MAIN)))
        assertFalse(ShareIntake.isShareIntent(Intent(Intent.ACTION_VIEW)))
        assertFalse(ShareIntake.isShareIntent(null))
    }

    @Test
    fun `gelen kutusu yazilamazsa hata manifesti yazmaya calisir, cokmez`() {
        // Kök dizin yerine düz bir DOSYA koymak dizin oluşturmayı başarısız kılar.
        val blocked = File(context.cacheDir, "engel_${System.nanoTime()}").also { it.writeText("dosya") }
        try {
            val brokenIntake = ShareIntake(context, ShareInbox(File(blocked, "share_inbox")))

            val id = brokenIntake.process(send(provide("1", displayName = "a.jpg")))

            assertNull(id)
        } finally {
            blocked.delete()
        }
    }
}
