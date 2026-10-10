package com.nearside.app.ui

/** A scanner instance delivers one usable payload and ignores queued frames after cancellation. */
internal class QrScanCaptureGate {
    private val seen = LinkedHashSet<String>()
    private var stopped = false

    @Synchronized
    fun accept(text: String, pairable: Boolean): Boolean {
        if (stopped || (!pairable && seen.size >= 32) || !seen.add(text)) return false
        if (pairable) {
            stopped = true
            seen.clear()
        }
        return true
    }

    @Synchronized
    fun stop() {
        stopped = true
        seen.clear()
    }
}
