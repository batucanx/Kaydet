package tr.com.pazarlik.kaydet

import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

class ShareInboxTest {
    private lateinit var root: File
    private lateinit var inbox: ShareInbox

    private val idA = "aaaaaaaa-0000-4000-8000-000000000001"
    private val idB = "bbbbbbbb-0000-4000-8000-000000000002"

    @Before
    fun setUp() {
        root = Files.createTempDirectory("kaydet_inbox").toFile()
        inbox = ShareInbox(root)
    }

    @After
    fun tearDown() {
        root.deleteRecursively()
    }

    private fun manifest(id: String, receivedAtMs: Long, vararg names: String) = JSONObject()
        .put("version", 1)
        .put("id", id)
        .put("source", "android-share")
        .put("receivedAtMs", receivedAtMs)
        .put(
            "files",
            JSONArray().apply {
                names.forEach { put(JSONObject().put("fileName", it).put("mimeType", "image/jpeg").put("sizeBytes", 1)) }
            },
        )

    private fun stage(id: String, receivedAtMs: Long, vararg names: String) {
        val dir = inbox.createPayloadDirectory(id)
        names.forEach { File(dir, it).writeBytes(byteArrayOf(1)) }
        inbox.writeManifest(id, manifest(id, receivedAtMs, *names))
    }

    @Test
    fun `manifest yazilmadan paylasim bekleyen sayilmaz`() {
        val dir = inbox.createPayloadDirectory(idA)
        File(dir, "yarim.jpg").writeBytes(byteArrayOf(1))

        assertTrue(inbox.readPending().isEmpty())
    }

    @Test
    fun `bekleyenler en eskiden yeniye siralanir`() {
        stage(idB, 2000, "b.jpg")
        stage(idA, 1000, "a.jpg")

        val pending = inbox.readPending().map { JSONObject(it).getString("id") }

        assertEquals(listOf(idA, idB), pending)
    }

    @Test
    fun `manifest atomik yazilir, gecici dosya kalmaz`() {
        stage(idA, 1, "a.jpg")

        val names = File(root, idA).list()!!.toSet()
        assertEquals(setOf("a.jpg", "manifest.json"), names)
    }

    @Test
    fun `acknowledge yalnizca manifesti siler, dosyalar kalir`() {
        stage(idA, 1, "a.jpg")

        inbox.acknowledge(idA)

        assertTrue(inbox.readPending().isEmpty())
        assertTrue(File(root, "$idA/a.jpg").isFile)
        assertFalse(File(root, "$idA/manifest.json").exists())
    }

    @Test
    fun `acknowledge tekrarlanirsa zararsizdir`() {
        stage(idA, 1, "a.jpg")

        inbox.acknowledge(idA)
        inbox.acknowledge(idA)

        assertTrue(File(root, "$idA/a.jpg").isFile)
    }

    @Test
    fun `discard dizini dosyalariyla siler`() {
        stage(idA, 1, "a.jpg")

        inbox.discard(idA)

        assertFalse(File(root, idA).exists())
    }

    @Test
    fun `gecersiz kimlikle silme ya da onaylama baska dizine dokunmaz`() {
        val victim = File(root.parentFile, "kaydet_victim_${System.nanoTime()}").apply {
            mkdirs()
            File(this, "manifest.json").writeText("{}")
        }
        try {
            for (bad in listOf("../${victim.name}", "..", "a/b", "", null, "kisa")) {
                inbox.acknowledge(bad)
                inbox.discard(bad)
            }
            assertTrue("dışarıdaki dizin silinmemeli", victim.isDirectory)
            assertTrue(File(victim, "manifest.json").isFile)
        } finally {
            victim.deleteRecursively()
        }
    }

    @Test
    fun `gecersiz kimlikle dizin olusturulamaz`() {
        for (bad in listOf("../x", "a/b", "..", "kisa")) {
            try {
                inbox.createPayloadDirectory(bad)
                fail("'$bad' kabul edilmemeli")
            } catch (_: IllegalArgumentException) {
                // beklenen
            }
        }
    }

    @Test
    fun `bozuk ya da dizin adiyla uyusmayan manifest atlanir`() {
        stage(idA, 1, "a.jpg")

        val corrupt = File(root, idB).apply { mkdirs() }
        File(corrupt, "manifest.json").writeText("{bozuk")

        val mismatched = File(root, "cccccccc-0000-4000-8000-000000000003").apply { mkdirs() }
        File(mismatched, "manifest.json").writeText(manifest(idA, 5, "x.jpg").toString())

        File(root, "tanimsiz_dizin").mkdirs()

        val pending = inbox.readPending().map { JSONObject(it).getString("id") }
        assertEquals(listOf(idA), pending)
    }

    @Test
    fun `kok dizin yoksa bos liste doner`() {
        assertEquals(emptyList<String>(), ShareInbox(File(root, "yok")).readPending())
    }

    @Test
    fun `kimlik dogrulamasi UUID kabul eder, yol ayiricilari reddeder`() {
        assertTrue(ShareInbox.isValidId(java.util.UUID.randomUUID().toString()))
        assertFalse(ShareInbox.isValidId("../etc"))
        assertFalse(ShareInbox.isValidId("a.b.c.d.e.f.g"))
        assertFalse(ShareInbox.isValidId(null))
    }
}
