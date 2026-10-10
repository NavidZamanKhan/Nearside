package com.nearside.app.diagnostics

import android.util.Log
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * Authoritative Nearside Error Code Registry.
 * Format: NS-[SUBSYSTEM]-[NUMBER]
 */
enum class NearsideErrorCode(val code: String, val subsystem: String) {
    // Discovery
    DISCOVERY_REGISTRATION_FAILED("NS-DISC-001", "discovery"),
    DISCOVERY_BROWSER_FAILED("NS-DISC-002", "discovery"),
    DISCOVERY_RESOLVE_FAILED("NS-DISC-003", "discovery"),

    // Pairing
    PAIRING_SESSION_EXPIRED("NS-PAIR-001", "pairing"),
    PAIRING_VERIFICATION_FAILED("NS-PAIR-002", "pairing"),
    PAIRING_RATE_LIMIT_EXCEEDED("NS-PAIR-003", "pairing"),
    PAIRING_MALFORMED_PAYLOAD("NS-PAIR-004", "pairing"),
    PAIRING_CAMERA_UNAVAILABLE("NS-PAIR-005", "pairing"),
    PAIRING_CAMERA_PERMISSION_DENIED("NS-PAIR-006", "pairing"),

    // Trust
    TRUST_UNTRUSTED_PEER("NS-TRUST-001", "trust"),
    TRUST_PEER_BLOCKED("NS-TRUST-002", "trust"),
    TRUST_KEY_MISMATCH("NS-TRUST-003", "trust"),
    TRUST_STORAGE_FAILED("NS-TRUST-004", "trust"),

    // Connection
    CONNECTION_TIMED_OUT("NS-CONN-001", "connection"),
    CONNECTION_REFUSED("NS-CONN-002", "connection"),
    CONNECTION_CLOSED("NS-CONN-003", "connection"),
    CONNECTION_BIND_FAILED("NS-CONN-004", "connection"),

    // Protocol
    PROTOCOL_MAGIC_MISMATCH("NS-PROTO-001", "protocol"),
    PROTOCOL_INVALID_FRAME_TYPE("NS-PROTO-002", "protocol"),
    PROTOCOL_DECODE_FAILED("NS-PROTO-003", "protocol"),
    PROTOCOL_PATH_TRAVERSAL_REJECTED("NS-PROTO-004", "protocol"),

    // Transfer
    TRANSFER_INTERRUPTED("NS-TRANSFER-001", "transfer"),
    TRANSFER_REJECTED("NS-TRANSFER-002", "transfer"),
    TRANSFER_RETRY_EXHAUSTED("NS-TRANSFER-003", "transfer"),
    TRANSFER_CANCELLED("NS-TRANSFER-004", "transfer"),

    // Verification
    VERIFY_CHUNK_MISMATCH("NS-VERIFY-001", "verification"),
    VERIFY_FILE_CHECKSUM_MISMATCH("NS-VERIFY-002", "verification"),

    // Storage
    STORAGE_READ_FAILED("NS-STORAGE-001", "storage"),
    STORAGE_WRITE_FAILED("NS-STORAGE-002", "storage");

    companion object {
        fun fromCode(code: String): NearsideErrorCode? {
            return values().firstOrNull { it.code == code }
        }
    }
}

/**
 * Central Nearside diagnostic error preserving stable Nearside classification and native cause.
 */
class NearsideError(
    val code: NearsideErrorCode,
    val operation: String,
    override val message: String,
    val subsystem: String = code.subsystem,
    val underlyingError: Throwable? = null,
    val correlationId: String? = null,
    val retryCount: Int? = null,
    val timestamp: Long = System.currentTimeMillis()
) : Exception(message, underlyingError) {

    override fun toString(): String {
        val parts = mutableListOf(
            "code=${code.code}",
            "subsystem=$subsystem",
            "operation=$operation",
            "message=\"$message\""
        )
        if (correlationId != null) parts.add("correlationId=$correlationId")
        if (retryCount != null) parts.add("retryCount=$retryCount")
        if (underlyingError != null) parts.add("underlying=\"${underlyingError.javaClass.simpleName}: ${underlyingError.message}\"")
        return "NearsideError(${parts.joinToString(", ")})"
    }
}

/**
 * Log level severity hierarchy.
 */
enum class DiagnosticLogLevel(val priority: Int) {
    DEBUG(0),
    INFO(1),
    WARN(2),
    ERROR(3)
}

/**
 * Privacy and security redactor to prevent leaking secrets, credentials, or raw payloads.
 */
object NearsideRedactor {
    fun sanitizePath(path: String): String {
        return File(path).name
    }

    fun sanitizeIdentity(identity: String): String {
        return if (identity.startsWith("ns1_") && identity.length > 12) {
            val prefix = identity.take(8)
            val suffix = identity.takeLast(4)
            "$prefix...$suffix"
        } else {
            identity
        }
    }

    fun redactSecret(value: String): String {
        return "[REDACTED:${value.length} chars]"
    }
}

/**
 * Central structured diagnostic logger for Nearside on Android.
 */
object NearsideLogger {
    var minimumLevel: DiagnosticLogLevel = DiagnosticLogLevel.INFO
    var logHandler: ((String) -> Unit)? = null

    private const val DEFAULT_TAG = "NearsideDiag"

    fun log(
        level: DiagnosticLogLevel,
        subsystem: String,
        operation: String,
        message: String,
        state: String? = null,
        correlationId: String? = null,
        errorCode: NearsideErrorCode? = null,
        retryCount: Int? = null,
        underlyingError: Throwable? = null,
        metadata: Map<String, String> = emptyMap()
    ) {
        if (level.priority < minimumLevel.priority) return

        val fields = mutableListOf(
            "level=${level.name}",
            "subsystem=$subsystem",
            "operation=$operation"
        )

        if (state != null) fields.add("state=$state")
        if (correlationId != null) fields.add("correlationId=$correlationId")
        if (errorCode != null) fields.add("errorCode=${errorCode.code}")
        if (retryCount != null) fields.add("retryCount=$retryCount")
        if (underlyingError != null) fields.add("underlying=\"${underlyingError.javaClass.simpleName}: ${underlyingError.message}\"")
        for ((k, v) in metadata.toSortedMap()) {
            fields.add("$k=\"$v\"")
        }
        fields.add("msg=\"$message\"")

        val line = fields.joinToString(" ")

        logHandler?.invoke(line) ?: run {
            try {
                when (level) {
                    DiagnosticLogLevel.DEBUG -> Log.d(DEFAULT_TAG, line)
                    DiagnosticLogLevel.INFO -> Log.i(DEFAULT_TAG, line)
                    DiagnosticLogLevel.WARN -> Log.w(DEFAULT_TAG, line)
                    DiagnosticLogLevel.ERROR -> Log.e(DEFAULT_TAG, line, underlyingError)
                }
            } catch (_: Throwable) {
                println("[$DEFAULT_TAG] $line")
            }
        }
    }

    fun debug(subsystem: String, operation: String, message: String, state: String? = null, correlationId: String? = null, metadata: Map<String, String> = emptyMap()) {
        log(DiagnosticLogLevel.DEBUG, subsystem, operation, message, state = state, correlationId = correlationId, metadata = metadata)
    }

    fun info(subsystem: String, operation: String, message: String, state: String? = null, correlationId: String? = null, metadata: Map<String, String> = emptyMap()) {
        log(DiagnosticLogLevel.INFO, subsystem, operation, message, state = state, correlationId = correlationId, metadata = metadata)
    }

    fun warn(subsystem: String, operation: String, message: String, state: String? = null, correlationId: String? = null, errorCode: NearsideErrorCode? = null, retryCount: Int? = null, underlyingError: Throwable? = null, metadata: Map<String, String> = emptyMap()) {
        log(DiagnosticLogLevel.WARN, subsystem, operation, message, state = state, correlationId = correlationId, errorCode = errorCode, retryCount = retryCount, underlyingError = underlyingError, metadata = metadata)
    }

    fun error(error: NearsideError, state: String? = null, metadata: Map<String, String> = emptyMap()) {
        log(
            level = DiagnosticLogLevel.ERROR,
            subsystem = error.subsystem,
            operation = error.operation,
            message = error.message,
            state = state,
            correlationId = error.correlationId,
            errorCode = error.code,
            retryCount = error.retryCount,
            underlyingError = error.underlyingError,
            metadata = metadata
        )
    }
}
