package com.nearside.app.service

import android.content.Context
import android.net.wifi.WifiManager
import android.os.PowerManager

interface LockDelegate {
    fun acquireWakeLock(timeoutMs: Long)
    fun releaseWakeLock()
    val isWakeLockHeld: Boolean

    fun acquireWifiLock()
    fun releaseWifiLock()
    val isWifiLockHeld: Boolean
}

class SystemLockDelegate(private val context: Context) : LockDelegate {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun acquireWakeLock(timeoutMs: Long) {
        try {
            if (wakeLock == null) {
                val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
                wakeLock = pm?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Nearside::TransferWakeLock")?.apply {
                    setReferenceCounted(false)
                }
            }
            wakeLock?.let { if (!it.isHeld) it.acquire(timeoutMs) }
        } catch (ignored: Exception) {}
    }

    override fun releaseWakeLock() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (ignored: Exception) {}
    }

    override val isWakeLockHeld: Boolean
        get() = wakeLock?.isHeld == true

    override fun acquireWifiLock() {
        try {
            if (wifiLock == null) {
                val wm = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                @Suppress("DEPRECATION")
                val wifiMode = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                wifiLock = wm?.createWifiLock(wifiMode, "Nearside::TransferWifiLock")?.apply {
                    setReferenceCounted(false)
                }
            }
            wifiLock?.let { if (!it.isHeld) it.acquire() }
        } catch (ignored: Exception) {}
    }

    override fun releaseWifiLock() {
        try {
            wifiLock?.let { if (it.isHeld) it.release() }
        } catch (ignored: Exception) {}
    }

    override val isWifiLockHeld: Boolean
        get() = wifiLock?.isHeld == true
}

class PowerLockManager(private val delegate: LockDelegate) {
    constructor(context: Context) : this(SystemLockDelegate(context))

    private val lock = Any()
    private val activeTransfers = mutableSetOf<String>()

    val activeCount: Int
        get() = synchronized(lock) { activeTransfers.size }

    val isHoldingLocks: Boolean
        get() = synchronized(lock) { delegate.isWakeLockHeld || delegate.isWifiLockHeld }

    fun acquire(tag: String, timeoutMs: Long = 10 * 60 * 1000L) {
        synchronized(lock) {
            val wasEmpty = activeTransfers.isEmpty()
            activeTransfers.add(tag)
            if (wasEmpty) {
                delegate.acquireWakeLock(timeoutMs)
                delegate.acquireWifiLock()
            }
        }
    }

    fun release(tag: String) {
        synchronized(lock) {
            activeTransfers.remove(tag)
            if (activeTransfers.isEmpty()) {
                delegate.releaseWakeLock()
                delegate.releaseWifiLock()
            }
        }
    }

    fun releaseAll() {
        synchronized(lock) {
            activeTransfers.clear()
            delegate.releaseWakeLock()
            delegate.releaseWifiLock()
        }
    }
}
