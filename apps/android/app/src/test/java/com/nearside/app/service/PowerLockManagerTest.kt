package com.nearside.app.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PowerLockManagerTest {

    class MockLockDelegate : LockDelegate {
        var wakeLockHeld: Boolean = false
        var wifiLockHeld: Boolean = false
        var lastTimeoutMs: Long = 0L

        override fun acquireWakeLock(timeoutMs: Long) {
            wakeLockHeld = true
            lastTimeoutMs = timeoutMs
        }

        override fun releaseWakeLock() {
            wakeLockHeld = false
        }

        override val isWakeLockHeld: Boolean
            get() = wakeLockHeld

        override fun acquireWifiLock() {
            wifiLockHeld = true
        }

        override fun releaseWifiLock() {
            wifiLockHeld = false
        }

        override val isWifiLockHeld: Boolean
            get() = wifiLockHeld
    }

    @Test
    fun testReferenceCountedAcquisitionAndRelease() {
        val mock = MockLockDelegate()
        val manager = PowerLockManager(mock)

        assertEquals(0, manager.activeCount)
        assertFalse(manager.isHoldingLocks)
        assertFalse(mock.wakeLockHeld)
        assertFalse(mock.wifiLockHeld)

        // 1st transfer starts
        manager.acquire("tx_1", timeoutMs = 60000L)
        assertEquals(1, manager.activeCount)
        assertTrue(manager.isHoldingLocks)
        assertTrue(mock.wakeLockHeld)
        assertTrue(mock.wifiLockHeld)
        assertEquals(60000L, mock.lastTimeoutMs)

        // 2nd transfer starts concurrently
        manager.acquire("tx_2")
        assertEquals(2, manager.activeCount)
        assertTrue(manager.isHoldingLocks)
        assertTrue(mock.wakeLockHeld)
        assertTrue(mock.wifiLockHeld)

        // 1st transfer finishes
        manager.release("tx_1")
        assertEquals(1, manager.activeCount)
        assertTrue(manager.isHoldingLocks)
        assertTrue(mock.wakeLockHeld)
        assertTrue(mock.wifiLockHeld)

        // 2nd transfer finishes
        manager.release("tx_2")
        assertEquals(0, manager.activeCount)
        assertFalse(manager.isHoldingLocks)
        assertFalse(mock.wakeLockHeld)
        assertFalse(mock.wifiLockHeld)
    }

    @Test
    fun testReleaseAllCleansUpLocksImmediately() {
        val mock = MockLockDelegate()
        val manager = PowerLockManager(mock)

        manager.acquire("tx_a")
        manager.acquire("tx_b")
        manager.acquire("tx_c")
        assertEquals(3, manager.activeCount)
        assertTrue(manager.isHoldingLocks)

        manager.releaseAll()
        assertEquals(0, manager.activeCount)
        assertFalse(manager.isHoldingLocks)
        assertFalse(mock.wakeLockHeld)
        assertFalse(mock.wifiLockHeld)
    }

    @Test
    fun testRedundantReleaseDoesNotCorruptState() {
        val mock = MockLockDelegate()
        val manager = PowerLockManager(mock)

        manager.acquire("tx_single")
        assertEquals(1, manager.activeCount)

        manager.release("non_existent_tx")
        assertEquals(1, manager.activeCount)
        assertTrue(manager.isHoldingLocks)

        manager.release("tx_single")
        assertEquals(0, manager.activeCount)
        assertFalse(manager.isHoldingLocks)

        // Additional redundant release
        manager.release("tx_single")
        assertEquals(0, manager.activeCount)
        assertFalse(manager.isHoldingLocks)
    }
}
