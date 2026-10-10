package com.nearside.app.ui

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class QrScanCaptureGateTest {
    @Test fun oneUsableCaptureSuppressesAllFollowingFrames() {
        val gate = QrScanCaptureGate()
        assertTrue(gate.accept("valid", pairable = true))
        assertFalse(gate.accept("valid", pairable = true))
        assertFalse(gate.accept("another valid", pairable = true))
    }

    @Test fun invalidFramesDoNotPreventLaterValidCapture() {
        val gate = QrScanCaptureGate()
        assertTrue(gate.accept("invalid", pairable = false))
        assertFalse(gate.accept("invalid", pairable = false))
        assertTrue(gate.accept("expired", pairable = false))
        assertFalse(gate.accept("invalid", pairable = false))
        assertTrue(gate.accept("fresh", pairable = true))
    }

    @Test fun cancelledScannerRejectsQueuedCaptureButNewScannerCanCapture() {
        val gate = QrScanCaptureGate()
        gate.stop()
        assertFalse(gate.accept("valid", pairable = true))
        assertTrue(QrScanCaptureGate().accept("valid", pairable = true))
    }

    @Test fun concurrentFramesDeliverExactlyOnce() {
        val gate = QrScanCaptureGate()
        val deliveries = AtomicInteger()
        val start = CountDownLatch(1)
        val workers = Executors.newFixedThreadPool(4)
        try {
            val results = (0 until 20).map { index -> workers.submit {
                start.await()
                if (gate.accept("valid $index", pairable = true)) deliveries.incrementAndGet()
            } }
            start.countDown()
            results.forEach { it.get() }
            assertEquals(1, deliveries.get())
        } finally { workers.shutdownNow() }
    }

    @Test fun invalidPayloadFloodRemainsBoundedWithoutBlockingPairing() {
        val gate = QrScanCaptureGate()
        val rejectedDeliveries = (0 until 1_000).count { gate.accept("invalid $it", pairable = false) }
        assertEquals(32, rejectedDeliveries)
        assertFalse(gate.accept("invalid 0", pairable = false))
        assertTrue(gate.accept("fresh pairing", pairable = true))
    }
}
