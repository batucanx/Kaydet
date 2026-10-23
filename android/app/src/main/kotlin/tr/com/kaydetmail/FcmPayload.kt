package tr.com.kaydetmail

/**
 * Sunucunun gönderdiği yalnızca-veri FCM mesajı (bkz. backend/src/notifier.ts
 * `notifyAndroid`). İleti içeriği (gönderen, konu) BİLEREK yoktur; uygulama
 * uyanınca iletiyi IMAP'ten kendisi çeker.
 *
 * FCM yalnızca `String -> String` taşır; bu yüzden sayılar ayrıştırılır ve
 * bozuk/eksik alanlar mesajı düşürmek yerine `null` kalır: hesap kimliği
 * bilinmiyorsa tüm hesaplar eşitlenir.
 */
data class FcmPayload(
    val accountId: Int?,
    val uid: Long?,
    val count: Int,
) {
    companion object {
        const val TYPE_NEW_MAIL = "new_mail"

        /** Tanınmayan türde (ya da türsüz) mesaj için `null` döner. */
        fun parse(data: Map<String, String>): FcmPayload? {
            if (data["type"] != TYPE_NEW_MAIL) return null
            return FcmPayload(
                accountId = data["accountId"]?.toIntOrNull(),
                uid = data["uid"]?.toLongOrNull(),
                count = data["count"]?.toIntOrNull()?.coerceAtLeast(1) ?: 1,
            )
        }
    }
}
