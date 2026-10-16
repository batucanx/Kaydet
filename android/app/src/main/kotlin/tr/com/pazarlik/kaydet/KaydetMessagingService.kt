package tr.com.pazarlik.kaydet

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
