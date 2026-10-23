package tr.com.kaydetmail

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.concurrent.futures.CallbackToFutureAdapter
import androidx.core.app.NotificationCompat
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.ListenableWorker
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.google.common.util.concurrent.ListenableFuture
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * FCM mesajı geldiğinde arka planda bir Dart isolate'i çalıştırıp posta
 * eşitlemesini yapar (Dart karşılığı: `fcmBackgroundSync`,
 * lib/app/background_sync.dart). iOS'taki `didReceiveRemoteNotification` →
 * `pushBackgroundSync` yolunun Android eşdeğeridir.
 *
 * Neden WorkManager: FCM servisi ~10 sn sonra dondurulur; hızlandırılmış iş
 * ise süreci ağ işlemi bitene dek canlı tutar, kota dolarsa normal işe düşer
 * (`RUN_AS_NON_EXPEDITED_WORK_REQUEST`) ve hata olunca üstel geri çekilmeyle
 * kendiliğinden yeniden denenir; elle yeniden deneme zamanlayıcısı gerekmez.
 */
class FcmSyncWorker(
    context: Context,
    params: WorkerParameters,
) : ListenableWorker(context, params) {
    companion object {
        private const val TAG = "KaydetFcmSync"
        private const val BACKGROUND_CHANNEL = "tr.com.kaydetmail/fcm_background"
        private const val ENTRY_LIBRARY = "package:kaydet/app/background_sync.dart"
        private const val ENTRY_FUNCTION = "fcmBackgroundSync"

        const val KEY_ACCOUNT_ID = "accountId"
        const val KEY_REASON = "reason"
        const val KEY_TOKEN = "token"
        const val REASON_MAIL = "mail"
        const val REASON_TOKEN = "token"

        /** Dart'ın yanıt vermesi için üst sınır; aşılırsa iş yeniden denenir. */
        private const val TIMEOUT_MS = 55_000L
        private const val MAX_ATTEMPTS = 4

        private const val NOTIFICATION_CHANNEL = "kaydet_sync"
        private const val NOTIFICATION_ID = 4211

        /**
         * Aynı anda YALNIZCA BİR Flutter motoru çalışır (ana iş parçacığında erişilir).
         *
         * Hesap başına ayrı benzersiz iş (bir hesabın hatası ötekini geciktirmesin
         * diye) WorkManager'da PARALEL koşar. Beş hesaba aynı anda ileti düşünce
         * (gece telefon kapalıydı, sabah açıldı) beş motor birden açılırdı: düşük
         * bellekli cihazda süreç öldürülür, Keystore/SQLite çekişmesi zaman aşımına
         * (55 sn) yol açar ve işler hep birlikte başarısız olurdu. Kapı, motorları
         * sıraya dizer; işler yine hesap başına bağımsız başarısız/yeniden dener.
         */
        private val gate = SerialGate()

        /** Aynı hesabın push'ları sıraya girer: devam eden eşitleme iptal edilmez. */
        fun enqueue(context: Context, accountId: Int?) {
            val key = if (accountId != null) "kaydet.fcm.sync.$accountId" else "kaydet.fcm.sync.all"
            val data = Data.Builder()
                .putString(KEY_REASON, REASON_MAIL)
                .apply { if (accountId != null) putInt(KEY_ACCOUNT_ID, accountId) }
                .build()
            submit(context, key, data, ExistingWorkPolicy.APPEND_OR_REPLACE)
        }

        fun enqueueTokenRefresh(context: Context, token: String) {
            val data = Data.Builder()
                .putString(KEY_REASON, REASON_TOKEN)
                .putString(KEY_TOKEN, token)
                .build()
            // Yalnızca en son token geçerli: öncekini değiştirmek yeterli.
            submit(context, "kaydet.fcm.token", data, ExistingWorkPolicy.REPLACE)
        }

        private fun submit(context: Context, uniqueName: String, data: Data, policy: ExistingWorkPolicy) {
            val request = OneTimeWorkRequestBuilder<FcmSyncWorker>()
                .setInputData(data)
                .setConstraints(
                    Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build(),
                )
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(uniqueName, policy, request)
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val finished = AtomicBoolean(false)
    private var engine: FlutterEngine? = null

    // Yalnızca ana iş parçacığında erişilir (bkz. SerialGate).
    private var gateTask: (() -> Unit)? = null
    private var gateHeld = false

    private fun gateFinish() {
        if (!gateHeld) return
        gateHeld = false
        gate.release()
    }

    override fun startWork(): ListenableFuture<Result> =
        CallbackToFutureAdapter.getFuture { completer ->
            mainHandler.post {
                val task: () -> Unit = {
                    gateHeld = true
                    try {
                        runEngine { success ->
                            if (!finished.compareAndSet(false, true)) return@runEngine
                            mainHandler.removeCallbacksAndMessages(null)
                            destroyEngine()
                            gateFinish()
                            if (success) FcmChannel.notifySynced()
                            completer.set(resultFor(success))
                        }
                    } catch (t: Throwable) {
                        Log.e(TAG, "Arka plan eşitlemesi başlatılamadı", t)
                        if (finished.compareAndSet(false, true)) {
                            destroyEngine()
                            gateFinish()
                            completer.set(resultFor(false))
                        }
                    }
                }
                gateTask = task
                gate.acquire(task)
            }
            "FcmSyncWorker"
        }

    /** Hızlandırılmış iş Android 12 öncesinde ön plan bildirimi ister. */
    override fun getForegroundInfoAsync(): ListenableFuture<ForegroundInfo> =
        CallbackToFutureAdapter.getFuture { completer ->
            completer.set(ForegroundInfo(NOTIFICATION_ID, buildNotification()))
            "FcmSyncWorker.foreground"
        }

    override fun onStopped() {
        // Sistem işi durdurdu (kota, kısıtlama): motoru bırak; iş yeniden denenir.
        mainHandler.post {
            // Henüz sırasını beklemekteyse kuyruktan çıkar; çalışıyorsa kapıyı aç.
            gateTask?.let { gate.remove(it) }
            finished.set(true)
            destroyEngine()
            gateFinish()
        }
    }

    private fun resultFor(success: Boolean): Result = when {
        success -> Result.success()
        runAttemptCount + 1 < MAX_ATTEMPTS -> Result.retry()
        // Sürekli başarısızlıkta sonsuz döngüye girme; periyodik görev yakalar.
        else -> Result.success()
    }

    private fun runEngine(onDone: (Boolean) -> Unit) {
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationComplete(applicationContext, null)

        val flutterEngine = FlutterEngine(applicationContext)
        engine = flutterEngine

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BACKGROUND_CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "takePayload" -> result.success(
                    mapOf(
                        KEY_ACCOUNT_ID to inputData.getInt(KEY_ACCOUNT_ID, -1).takeIf { it >= 0 },
                        KEY_REASON to (inputData.getString(KEY_REASON) ?: REASON_MAIL),
                        KEY_TOKEN to inputData.getString(KEY_TOKEN),
                    ),
                )
                "syncComplete" -> {
                    result.success(null)
                    onDone(call.argument<Boolean>("success") ?: false)
                }
                else -> result.notImplemented()
            }
        }

        mainHandler.postDelayed({
            Log.w(TAG, "Dart eşitlemesi zaman aşımına uğradı")
            onDone(false)
        }, TIMEOUT_MS)

        flutterEngine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), ENTRY_LIBRARY, ENTRY_FUNCTION),
        )
    }

    private fun destroyEngine() {
        engine?.destroy()
        engine = null
    }

    private fun buildNotification(): Notification {
        val manager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(NOTIFICATION_CHANNEL, "Posta eşitleme", NotificationManager.IMPORTANCE_MIN),
            )
        }
        return NotificationCompat.Builder(applicationContext, NOTIFICATION_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_kaydet)
            .setContentTitle("Kaydet")
            .setContentText("Posta eşitleniyor")
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setOngoing(true)
            .build()
    }
}
