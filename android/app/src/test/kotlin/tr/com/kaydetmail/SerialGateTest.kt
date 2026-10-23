package tr.com.kaydetmail

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Beş hesaba aynı anda push gelince [FcmSyncWorker]'ın beş Flutter motorunu
 * birden değil, sırayla açmasını sağlayan kapı.
 */
class SerialGateTest {
    @Test
    fun firstTaskRunsImmediatelyAndLaterOnesWaitForRelease() {
        val gate = SerialGate()
        val log = mutableListOf<String>()

        gate.acquire { log += "a" }
        gate.acquire { log += "b" }
        gate.acquire { log += "c" }

        assertEquals(listOf("a"), log) // yalnızca biri çalışıyor
        assertEquals(2, gate.waiting)

        gate.release()
        assertEquals(listOf("a", "b"), log)
        gate.release()
        assertEquals(listOf("a", "b", "c"), log)
        assertTrue(gate.isBusy) // c henüz bitmedi
        gate.release()
        assertFalse(gate.isBusy)
    }

    @Test
    fun fiveAccountsNeverRunConcurrently() {
        val gate = SerialGate()
        var running = 0
        var maxRunning = 0
        val order = mutableListOf<Int>()

        for (account in 1..5) {
            gate.acquire {
                running++
                maxRunning = maxOf(maxRunning, running)
                order += account
            }
        }
        // Her iş bitince (motor yok edilince) kapı bırakılır.
        repeat(5) {
            running--
            gate.release()
        }

        assertEquals(1, maxRunning)
        assertEquals(listOf(1, 2, 3, 4, 5), order)
        assertFalse(gate.isBusy)
    }

    @Test
    fun removedWaitingTaskNeverRuns() {
        val gate = SerialGate()
        val log = mutableListOf<String>()
        val second: () -> Unit = { log += "b" }

        gate.acquire { log += "a" }
        gate.acquire(second)
        gate.acquire { log += "c" }

        assertTrue(gate.remove(second)) // sistem bekleyen işi iptal etti
        gate.release()

        assertEquals(listOf("a", "c"), log)
    }

    @Test
    fun removeOfAlreadyStartedTaskIsHarmless() {
        val gate = SerialGate()
        val running: () -> Unit = {}
        gate.acquire(running)

        assertFalse(gate.remove(running)) // kuyrukta değil; çalışıyor
        assertTrue(gate.isBusy)
    }

    @Test
    fun gateIsReusableAfterDraining() {
        val gate = SerialGate()
        var runs = 0

        gate.acquire { runs++ }
        gate.release()
        gate.acquire { runs++ }

        assertEquals(2, runs)
        assertTrue(gate.isBusy)
    }

    @Test
    fun releaseWithoutTaskIsSafe() {
        val gate = SerialGate()
        gate.release()
        assertFalse(gate.isBusy)
    }
}
