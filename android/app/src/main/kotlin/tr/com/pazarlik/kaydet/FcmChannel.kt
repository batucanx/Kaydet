package tr.com.pazarlik.kaydet

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * FCM ↔ ana Flutter isolate köprüsü (Dart karşılığı: `AndroidPushChannel`).
 *
 * Flutter'ın `firebase_messaging` eklentisi KASITLI olarak kullanılmaz: o
 * eklenti iOS'a da bağlanır ve iOS'ta APNs delege zincirine girer; çalışan iOS
 * push yolunu riske atmamak için FCM yalnızca Android'de, burada, doğrudan
 * Firebase Android SDK'sıyla konuşur.
 *
 * Ana motor yaşarken bu kanal tek "ön plan" tarafıdır; uygulama arka
 * plandayken ya da öldürülmüşken FCM mesajı [FcmSyncWorker] ile işlenir.
 */
class FcmChannel(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL_NAME = "tr.com.pazarlik.kaydet/fcm"
        private const val TAG = "KaydetFcm"

        /** Ana motor ve etkin kanal; yoksa mesajlar işçiyle işlenir. */
        @Volatile
        private var active: FcmChannel? = null

        /** Activity görünür mü? (`MainActivity` onStart/onStop). */
        @Volatile
        var appInForeground: Boolean = false

        /**
         * Ana isolate canlı ve kullanıcı uygulamaya bakıyorsa push'u ona
         * iletir ve `true` döner. Böylece liste aynı isolate'te güncellenir
         * (bkz. iOS'taki `onRemotePush` ile aynı gerekçe).
         */
        fun deliverPushToForeground(accountId: Int?): Boolean {
            val channel = active ?: return false
            if (!appInForeground) return false
            channel.postToDart("onPush", mapOf("accountId" to accountId))
            return true
        }

        fun deliverTokenRefresh(token: String) {
            active?.postToDart("onToken", token)
        }

        /** Firebase yapılandırılmış mı? (`google-services.json` yoksa hayır.) */
        fun isFirebaseConfigured(context: Context): Boolean =
            try {
                FirebaseApp.getApps(context.applicationContext).isNotEmpty()
            } catch (_: Throwable) {
                false
            }
    }

    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val disposed = AtomicBoolean(false)

    init {
        channel.setMethodCallHandler(this)
        active = this
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getToken" -> fetchToken(result)
            else -> result.notImplemented()
        }
    }

    /**
     * Token'ı verir; Firebase yapılandırılmamışsa ya da cihazda Google Play
     * hizmetleri yoksa `null` (Dart bu durumda ön plan servisine düşer).
     */
    private fun fetchToken(result: MethodChannel.Result) {
        if (!isFirebaseConfigured(context)) {
            result.success(null)
            return
        }
        try {
            FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                if (task.isSuccessful) {
                    result.success(task.result)
                } else {
                    Log.w(TAG, "FCM token alınamadı", task.exception)
                    result.success(null)
                }
            }
        } catch (e: Throwable) {
            Log.w(TAG, "FCM kullanılamıyor", e)
            result.success(null)
        }
    }

    private fun postToDart(method: String, arguments: Any?) {
        mainHandler.post {
            if (!disposed.get()) channel.invokeMethod(method, arguments)
        }
    }

    fun dispose() {
        disposed.set(true)
        channel.setMethodCallHandler(null)
        if (active === this) active = null
    }
}
