package tr.com.pazarlik.kaydet

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * Sistem "Paylaş" menüsü ↔ Flutter köprüsü (Dart karşılığı:
 * `ShareIntakeService`, kanal adı aynı).
 *
 * **Sözleşme:** paylaşım Flutter'a İTİLMEZ, diske yazılır; Flutter hazır olunca
 * `takePendingShares` ile ÇEKER. Tek "itme" içeriksiz `onShareReceived`
 * dürtmesidir; Dart dinleyicisi henüz kurulmamışsa kaybolması hiçbir şeyi
 * kaybettirmez (bkz. `ShareIntakeService`'in belgesi).
 *
 * Tüm G/Ç TEK iş parçacıklı bir sırada çalışır. Bu, soğuk başlangıçta Dart'ın
 * `takePendingShares` çağrısının aynı paylaşımın kopyası BİTMEDEN cevap
 * vermesini de engeller: çağrı kopyalamanın arkasına dizilir.
 */
class ShareChannel(context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL_NAME = "tr.com.pazarlik.kaydet/share"
        private const val TAG = "KaydetShare"

        /**
         * Son işlenen Intent. Activity yeniden yaratılınca (yapılandırma
         * değişikliği, işlem ölümü sonrası geri yükleme) sistem AYNI Intent'i
         * yeniden teslim edebilir; yeni bir paylaşım sanılıp iki kez işlenmesin.
         * Sınıf-düzeyinde: Activity/ShareChannel yeniden yaratılsa da yaşar.
         */
        @Volatile
        private var lastHandledIntent: WeakReference<Intent>? = null
    }

    private val inbox = ShareInbox(File(context.applicationContext.filesDir, ShareInbox.DIRECTORY_NAME))
    private val intake = ShareIntake(context.applicationContext, inbox)
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "kaydet-share").apply { isDaemon = true }
    }
    private val mainHandler = Handler(Looper.getMainLooper())

    init {
        inbox.root.mkdirs()
        channel.setMethodCallHandler(this)
    }

    /**
     * `onCreate`/`onNewIntent`ten çağrılır. Paylaşım Intent'i değilse ya da
     * daha önce işlendiyse hiçbir şey yapmaz.
     */
    fun handleIntent(intent: Intent?) {
        if (intent == null || !ShareIntake.isShareIntent(intent)) return

        // Son uygulamalar (recents) listesinden geri getirilen görev, ilk
        // başlatan Intent'i yeniden teslim eder — yeni paylaşım DEĞİLDİR.
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return

        synchronized(ShareChannel::class.java) {
            if (lastHandledIntent?.get() === intent) return
            lastHandledIntent = WeakReference(intent)
        }

        try {
            executor.execute {
                intake.process(intent)
                // Başarılı da olsa hata manifesti de olsa Dart'a haber ver.
                mainHandler.post { notifyShareAvailable() }
            }
        } catch (_: RejectedExecutionException) {
            // Kanal kapatılmış (Activity yok edildi); paylaşım bu turda işlenemedi.
            Log.w(TAG, "Paylaşım işlenemedi: kanal kapalı")
        }
    }

    private fun notifyShareAvailable() {
        try {
            channel.invokeMethod("onShareReceived", null)
        } catch (error: Throwable) {
            // Motor kapanmış olabilir; veri diskte bekler, sonraki açılışta çekilir.
            Log.w(TAG, "Dart'a dürtme gönderilemedi", error)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "takePendingShares" -> runAsync(result) {
                mapOf("root" to inbox.root.path, "payloads" to inbox.readPending())
            }
            "acknowledgeShare" -> runAsync(result) {
                inbox.acknowledge(call.argument<String>("id"))
                null
            }
            "discardShare" -> runAsync(result) {
                inbox.discard(call.argument<String>("id"))
                null
            }
            "inboxRoot" -> result.success(inbox.root.path)
            else -> result.notImplemented()
        }
    }

    /** İşi sıraya koyar; sonucu ana iş parçacığında Flutter'a döner. Hata çökertmez. */
    private fun runAsync(result: MethodChannel.Result, work: () -> Any?) {
        try {
            executor.execute {
                val outcome = try {
                    Result.success(work())
                } catch (error: Throwable) {
                    Log.e(TAG, "Kanal işlemi başarısız", error)
                    Result.failure(error)
                }
                mainHandler.post {
                    outcome.fold(
                        onSuccess = { result.success(it) },
                        onFailure = { result.error("share_failed", it.message, null) },
                    )
                }
            }
        } catch (_: RejectedExecutionException) {
            result.error("share_unavailable", "Paylaşım kanalı kapalı", null)
        }
    }

    /**
     * Motor koparken çağrılır. Sıradaki (ve süren) kopyalar TAMAMLANIR — kullanıcı
     * paylaşırken uygulamadan çıksa bile paylaşım kaybolmaz.
     */
    fun dispose() {
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }
}
