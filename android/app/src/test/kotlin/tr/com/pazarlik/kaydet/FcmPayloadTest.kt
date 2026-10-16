package tr.com.pazarlik.kaydet

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class FcmPayloadTest {
    @Test
    fun `sunucunun gonderdigi yuk ayristirilir`() {
        val payload = FcmPayload.parse(
            mapOf(
                "type" to "new_mail",
                "accountId" to "4",
                "folder" to "INBOX",
                "uid" to "11",
                "count" to "2",
                "uidValidity" to "99",
            ),
        )
        assertEquals(FcmPayload(accountId = 4, uid = 11L, count = 2), payload)
    }

    @Test
    fun `taninmayan ya da turu olmayan mesaj yok sayilir`() {
        assertNull(FcmPayload.parse(emptyMap()))
        assertNull(FcmPayload.parse(mapOf("type" to "marketing", "accountId" to "1")))
    }

    @Test
    fun `bozuk alanlar mesaji dusurmez, bilinmeyen kalir`() {
        val payload = FcmPayload.parse(
            mapOf("type" to "new_mail", "accountId" to "abc", "uid" to "", "count" to "-5"),
        )
        assertEquals(FcmPayload(accountId = null, uid = null, count = 1), payload)
    }

    @Test
    fun `hesap kimligi yoksa tum hesaplar eslenir`() {
        assertNull(FcmPayload.parse(mapOf("type" to "new_mail"))!!.accountId)
    }
}
