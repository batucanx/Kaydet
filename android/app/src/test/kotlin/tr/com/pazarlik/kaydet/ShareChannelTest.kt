package tr.com.pazarlik.kaydet

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import java.io.File
import java.nio.ByteBuffer

/**
 * `ShareChannel`in yaşam döngüsü korumaları: aynı Intent'in tekrar işlenmemesi,
 * recents'ten geri yükleme, kopya bitmeden okumanın cevap vermemesi.
 */
@RunWith(RobolectricTestRunner::class)
class ShareChannelTest {
    /** Dart tarafına giden mesajları kaydeden sahte mesajlaşma altyapısı. */
    private class FakeMessenger : BinaryMessenger {
        val sent = mutableListOf<MethodCall>()

        override fun send(channel: String, message: ByteBuffer?) = record(channel, message)

        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) =
            record(channel, message)

        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) = Unit

        private fun record(channel: String, message: ByteBuffer?) {
            if (channel != ShareChannel.CHANNEL_NAME || message == null) return
            message.rewind()
            sent.add(StandardMethodCodec.INSTANCE.decodeMethodCall(message))
        }
    }

    /** `MethodChannel.Result`ın sonucunu bekleyen yakalayıcı. */
    private class Capture : MethodChannel.Result {
        @Volatile var done = false
        @Volatile var value: Any? = null
        @Volatile var errorCode: String? = null

        override fun success(result: Any?) {
            value = result
            done = true
        }

        override fun error(code: String, message: String?, details: Any?) {
            errorCode = code
            done = true
        }

        override fun notImplemented() {
            errorCode = "not_implemented"
            done = true
        }
    }

    private lateinit var context: Context
    private lateinit var messenger: FakeMessenger
    private lateinit var channel: ShareChannel
    private lateinit var inboxRoot: File
    private val sources = mutableListOf<File>()

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        inboxRoot = File(context.filesDir, ShareInbox.DIRECTORY_NAME).also { it.deleteRecursively() }
        messenger = FakeMessenger()
        channel = ShareChannel(context, messenger)
        ShareIntakeTest.FakeProvider.entries.clear()
        Robolectric.setupContentProvider(
            ShareIntakeTest.FakeProvider::class.java,
            ShareIntakeTest.FakeProvider.AUTHORITY,
        )
    }

    @After
    fun tearDown() {
        channel.dispose()
        inboxRoot.deleteRecursively()
        sources.forEach { it.delete() }
    }

    private fun shareIntent(key: String, name: String): Intent {
        val file = File.createTempFile("src_", ".bin").also { sources.add(it); it.writeBytes(byteArrayOf(1, 2, 3)) }
        ShareIntakeTest.FakeProvider.entries[key] =
            ShareIntakeTest.Entry(name, 3, "image/jpeg", file)
        return Intent(Intent.ACTION_SEND).setType("image/*").putExtra(
            Intent.EXTRA_STREAM,
            Uri.parse("content://${ShareIntakeTest.FakeProvider.AUTHORITY}/$key"),
        )
    }

    /** Ana Looper'ı boşaltarak (arka plan iş parçacığının `post`unu işleyerek) sonucu bekler. */
    private fun call(method: String, vararg args: Pair<String, Any?>): Capture {
        val capture = Capture()
        channel.onMethodCall(MethodCall(method, args.toMap()), capture)
        val deadline = System.currentTimeMillis() + 10_000
        while (!capture.done && System.currentTimeMillis() < deadline) {
            shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(5)
        }
        assertTrue("$method zaman aşımına uğradı", capture.done)
        return capture
    }

    @Suppress("UNCHECKED_CAST")
    private fun pendingPayloads(): List<JSONObject> {
        val reply = call("takePendingShares").value as Map<String, Any?>
        assertEquals(inboxRoot.path, reply["root"])
        return (reply["payloads"] as List<String>).map(::JSONObject)
    }

    private fun drainMainLooper() {
        // Arka plan iş parçacığındaki dürtme `post`unun yetişmesi için kısa bekleme.
        repeat(20) {
            shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(5)
        }
    }

    @Test
    fun `cekme, ayni paylasimin kopyasi bitmeden cevap vermez (FIFO)`() {
        // Soğuk başlangıç: onCreate paylaşımı sıraya koyar, Dart hemen ardından çeker.
        channel.handleIntent(shareIntent("1", "foto.jpg"))

        val payloads = pendingPayloads()

        assertEquals(1, payloads.size)
        assertEquals("foto.jpg", payloads[0].getJSONArray("files").getJSONObject(0).getString("fileName"))
    }

    @Test
    fun `paylasim bitince Dart'a icerksiz dürtme gonderilir`() {
        channel.handleIntent(shareIntent("1", "foto.jpg"))
        pendingPayloads() // kopya bitti
        drainMainLooper()

        assertEquals(listOf("onShareReceived"), messenger.sent.map { it.method })
        assertEquals(null, messenger.sent.single().arguments)
    }

    @Test
    fun `ayni Intent nesnesi ikinci kez islenmez`() {
        val intent = shareIntent("1", "foto.jpg")

        channel.handleIntent(intent)
        channel.handleIntent(intent) // Activity yeniden yaratıldı / onNewIntent tekrarı
        channel.handleIntent(intent)

        assertEquals(1, pendingPayloads().size)
    }

    @Test
    fun `farkli Intent'ler ayri paylasim olur`() {
        channel.handleIntent(shareIntent("1", "bir.jpg"))
        channel.handleIntent(shareIntent("2", "iki.jpg"))

        val names = pendingPayloads().map {
            it.getJSONArray("files").getJSONObject(0).getString("fileName")
        }
        assertEquals(listOf("bir.jpg", "iki.jpg"), names)
    }

    @Test
    fun `recents'ten geri yuklenen gorev yeni paylasim sayilmaz`() {
        val intent = shareIntent("1", "foto.jpg").addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY)

        channel.handleIntent(intent)

        assertTrue(pendingPayloads().isEmpty())
    }

    @Test
    fun `paylasim olmayan Intent ve null yok sayilir`() {
        channel.handleIntent(Intent(Intent.ACTION_MAIN))
        channel.handleIntent(Intent(Intent.ACTION_VIEW, Uri.parse("https://ornek.com")))
        channel.handleIntent(null)

        assertTrue(pendingPayloads().isEmpty())
        assertTrue(messenger.sent.isEmpty())
    }

    @Test
    fun `acknowledge tuketir, tekrar cekmede gelmez, dosya kalir`() {
        channel.handleIntent(shareIntent("1", "foto.jpg"))
        val id = pendingPayloads().single().getString("id")

        call("acknowledgeShare", "id" to id)

        assertTrue(pendingPayloads().isEmpty())
        assertTrue(File(inboxRoot, "$id/foto.jpg").isFile)
    }

    @Test
    fun `discard dosyalariyla siler`() {
        channel.handleIntent(shareIntent("1", "foto.jpg"))
        val id = pendingPayloads().single().getString("id")

        call("discardShare", "id" to id)

        assertFalse(File(inboxRoot, id).exists())
    }

    @Test
    fun `gecersiz kimlikli acknowledge cokmez`() {
        val result = call("acknowledgeShare", "id" to "../../etc")
        assertEquals(null, result.errorCode)

        val missing = call("acknowledgeShare")
        assertEquals(null, missing.errorCode)
    }

    @Test
    fun `tanimsiz yontem notImplemented doner, inboxRoot yolu verir`() {
        assertEquals("not_implemented", call("bilinmeyen").errorCode)
        assertEquals(inboxRoot.path, call("inboxRoot").value)
    }

    @Test
    fun `dispose sonrasi gelen paylasim cokmez`() {
        channel.dispose()

        channel.handleIntent(shareIntent("1", "foto.jpg"))

        assertNotNull(channel)
    }
}
