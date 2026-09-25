package tr.com.pazarlik.kaydet

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ShareFileNameTest {
    private val mimeExtensions = mapOf(
        "image/jpeg" to "jpg",
        "application/pdf" to "pdf",
    )

    private fun sanitize(raw: String?, mime: String? = null) =
        ShareFileName.sanitize(raw, mime) { mimeExtensions[it] }

    @Test
    fun `normal ad ve uzanti korunur`() {
        assertEquals("foto.jpg", sanitize("foto.jpg"))
        assertEquals("Şirket Raporu Çğüö.pdf", sanitize("Şirket Raporu Çğüö.pdf"))
        assertEquals("arsiv.tar.gz", sanitize("arsiv.tar.gz"))
    }

    @Test
    fun `yol gecisi son bilesene indirilir`() {
        assertEquals("passwd", sanitize("../../etc/passwd"))
        assertEquals("passwd", sanitize("..\\..\\etc\\passwd"))
        assertEquals("b.jpg", sanitize("a/b.jpg"))
        assertEquals("ek", sanitize(".."))
        assertEquals("ek", sanitize("."))
        assertEquals("ek", sanitize("/"))
    }

    @Test
    fun `sonuc asla yol ayirici ya da bastaki nokta icermez`() {
        val hostile = listOf(
            "../x", "..\\x", "/etc/passwd", ".hidden", "..hidden", "a/../b", "  ..  ",
            "C:\\Windows\\system32\\cmd.exe", "x\u0000y", "\n", "a\tb", "<>:\"|?*",
        )
        for (raw in hostile) {
            val name = sanitize(raw)
            assertFalse("'$raw' -> '$name'", name.contains('/') || name.contains('\\'))
            assertFalse("'$raw' -> '$name'", name.startsWith("."))
            assertFalse("'$raw' -> '$name'", name.contains('\u0000'))
            assertTrue("'$raw' -> '$name'", name.isNotEmpty())
            assertTrue("'$raw' -> '$name'", name != ".." && name != ".")
        }
    }

    @Test
    fun `kontrol ve windows-gecersiz karakterler temizlenir`() {
        assertEquals("ab.txt", sanitize("a\u0000b.txt"))
        assertEquals("a_b.txt", sanitize("a:b.txt"))
        assertEquals("rapor_.pdf", sanitize("rapor?.pdf"))
    }

    @Test
    fun `bos ya da null ad yedek ada duser`() {
        assertEquals("ek", sanitize(null))
        assertEquals("ek", sanitize(""))
        assertEquals("ek", sanitize("   "))
    }

    @Test
    fun `uzantisiz ad MIME turunden uzanti alir`() {
        assertEquals("foto.jpg", sanitize("foto", "image/jpeg"))
        assertEquals("ek.pdf", sanitize(null, "application/pdf"))
        // Tanınmayan MIME: uzantı eklenmez.
        assertEquals("foto", sanitize("foto", "application/x-bilinmeyen"))
        // Var olan uzantı MIME'a rağmen korunur.
        assertEquals("foto.png", sanitize("foto.png", "image/jpeg"))
    }

    @Test
    fun `cok uzun ad bayt sinirina indirilir ve uzanti korunur`() {
        val name = sanitize("ş".repeat(500) + ".jpg")
        assertTrue(name.endsWith(".jpg"))
        assertTrue(name.toByteArray(Charsets.UTF_8).size <= 255)

        // 4 baytlık karakterler (emoji) yarıda kesilmez.
        val emoji = sanitize("😀".repeat(200) + ".png")
        assertTrue(emoji.endsWith(".png"))
        assertTrue(emoji.toByteArray(Charsets.UTF_8).size <= 255)
        assertFalse(emoji.contains('\uFFFD'))
        assertEquals(emoji, String(emoji.toByteArray(Charsets.UTF_8), Charsets.UTF_8))
    }

    @Test
    fun `gercek uzanti olmayan sonek uzanti sayilmaz`() {
        // Çok uzun "uzantı" gerçekte uzantı değildir.
        val name = sanitize("not.buCokUzunBirSonekTirRakam")
        assertEquals("not.buCokUzunBirSonekTirRakam", name)
        assertEquals("ek", sanitize("....."))
    }

    @Test
    fun `ayni paylasimdaki cakisan adlar sirayla numaralanir`() {
        assertEquals("image.jpg", ShareFileName.unique("image.jpg", emptySet()))
        assertEquals("image (2).jpg", ShareFileName.unique("image.jpg", setOf("image.jpg")))
        assertEquals(
            "image (3).jpg",
            ShareFileName.unique("image.jpg", setOf("image.jpg", "image (2).jpg")),
        )
        // Büyük/küçük harf duyarsız: iOS/Windows dosya sistemleri aynı adı çakışma sayar.
        assertEquals("Image (2).JPG", ShareFileName.unique("Image.JPG", setOf("image.jpg")))
        assertEquals("notlar (2)", ShareFileName.unique("notlar", setOf("notlar")))
    }
}
