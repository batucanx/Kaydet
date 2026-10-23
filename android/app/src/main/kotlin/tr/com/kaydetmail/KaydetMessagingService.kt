package tr.com.kaydetmail

import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * FCM girişi. Sunucu (bkz. backend/src/fcm.ts) yalnızca-veri, yüksek öncelikli
 * mesaj gönderir; bu servis süreç ölü olsa bile sistem tarafından başlatılır.
 *
 * `onMessageReceived` yalnızca ~10 sn çalışabilir ve süreç sonra dondurulur;
 * IMAP eşitlemesi bunun içinde YAPILMAZ. Uygulama önde değilse iş, sistemin
 * "hızlandırılmış" (expedited) görevi olarak [FcmSyncWorker]'a devredilir.
 */
class KaydetMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        val payload = FcmPayload.parse(message.data)
        if (payload == null) {
            Log.w(TAG, "Tanınmayan FCM mesajı yok sayıldı")
            return
        }
        if (FcmChannel.deliverPushToForeground(payload.accountId)) return
        FcmSyncWorker.enqueue(applicationContext, payload.accountId)
    }

    /**
     * FCM sunucusu bu cihaza ait bekleyen mesajları SİLDİ: cihaz uzun süre
     * ulaşılamazdı (bekleyen mesaj sayısı 100'ü aştı, ya da bir aydan eski),
     * ya da Doze/uçak modu sırasında saklama sınırları doldu. Hangi hesapların
     * push'u düştüğü bilinemez; bu yüzden TÜM hesaplar eşitlenir (hesap
     * kimliksiz iş). Bu çağrı olmasaydı düşen push'lar sessizce kaybolur,
     * bildirimler ancak periyodik görev gelince (en erken ~15 dk) görünürdü.
     */
    override fun onDeletedMessages() {
        Log.w(TAG, "FCM bekleyen mesajları sildi; tüm hesaplar eşitleniyor")
        FcmSyncWorker.enqueue(applicationContext, null)
    }

    /**
     * Token yenilendi. Ana isolate canlıysa kendisi sunucuya bildirir; değilse
     * (ya da bildirim kaçarsa) eski token sunucuda UNREGISTERED alıp silinir ve
     * kullanıcı push'tan sessizce düşerdi. Bu yüzden arka planda da yeniden
     * kayıt işi sıraya alınır.
     */
    override fun onNewToken(token: String) {
        FcmChannel.deliverTokenRefresh(token)
        FcmSyncWorker.enqueueTokenRefresh(applicationContext, token)
    }

    private companion object {
        const val TAG = "KaydetFcm"
    }
}
