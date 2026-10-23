package tr.com.pazarlik.kaydet

/**
 * İşleri SIRAYLA, birer birer çalıştıran basit kapı (iş parçacığı güvenli
 * DEĞİL: yalnızca tek bir iş parçacığından, burada ana iş parçacığından
 * kullanılır).
 *
 * [FcmSyncWorker] beş hesaba aynı anda push gelince WorkManager'ın işleri
 * paralel koşturup beş Flutter motoru birden açmasını önlemek için kullanır
 * (bkz. oradaki açıklama).
 *
 * Sözleşme: [acquire] ile verilen her iş, ya hemen ya da önceki iş [release]
 * edilince çalışır; çalışan işin tam olarak BİR kez [release] çağırması gerekir.
 * Sırada bekleyen bir iş artık gerekmiyorsa [remove] ile çıkarılır.
 */
class SerialGate {
    private val queue = ArrayDeque<() -> Unit>()
    private var busy = false

    /** Kapı boşsa [task]'ı hemen çalıştırır, değilse sıraya koyar. */
    fun acquire(task: () -> Unit) {
        if (busy) {
            queue.addLast(task)
        } else {
            busy = true
            task()
        }
    }

    /** Çalışan iş bitti: sıradaki varsa onu başlatır, yoksa kapıyı boşaltır. */
    fun release() {
        val next = queue.removeFirstOrNull()
        if (next == null) busy = false else next()
    }

    /** Henüz başlamamış bir işi sıradan çıkarır; çıkarıldıysa `true`. */
    fun remove(task: () -> Unit): Boolean = queue.remove(task)

    val isBusy: Boolean get() = busy

    val waiting: Int get() = queue.size
}
