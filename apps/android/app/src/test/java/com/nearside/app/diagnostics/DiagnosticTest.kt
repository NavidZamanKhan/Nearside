package com.nearside.app.diagnostics

import com.nearside.app.model.DevicePlatform
import com.nearside.app.model.TransferDirection
import com.nearside.app.model.TransferRecord
import com.nearside.app.model.TransferStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

class DiagnosticTest {

    @Test
    fun testErrorCodeRegistryFormat() {
        val pattern = Regex("^NS-[A-Z]+-[0-9]{3}$")
        for (code in NearsideErrorCode.values()) {
            assertTrue("Code ${code.code} must match format", pattern.matches(code.code))
            assertNotNull("Subsystem must be defined", code.subsystem)
            assertEquals("Lookup by code string should succeed", code, NearsideErrorCode.fromCode(code.code))
        }
    }

    @Test
    fun testNearsideErrorPreservesNativeCause() {
        val nativeCause = IOException("Connection reset by peer")
        val error = NearsideError(
            code = NearsideErrorCode.CONNECTION_CLOSED,
            operation = "receiveChunks",
            message = "Socket stream closed unexpectedly",
            underlyingError = nativeCause,
            correlationId = "tx_abc789",
            retryCount = 2
        )

        assertEquals(NearsideErrorCode.CONNECTION_CLOSED, error.code)
        assertEquals("connection", error.subsystem)
        assertEquals("receiveChunks", error.operation)
        assertEquals("tx_abc789", error.correlationId)
        assertEquals(2, error.retryCount)
        assertEquals(nativeCause, error.underlyingError)

        val str = error.toString()
        assertTrue(str.contains("code=NS-CONN-003"))
        assertTrue(str.contains("correlationId=tx_abc789"))
        assertTrue(str.contains("IOException: Connection reset by peer"))
    }

    @Test
    fun testNearsideLoggerStructuredFormatting() {
        val captured = mutableListOf<String>()
        NearsideLogger.logHandler = { line -> captured.add(line) }

        NearsideLogger.info(
            subsystem = "transfer",
            operation = "sendFiles",
            message = "Starting outbound transfer",
            state = "connecting",
            correlationId = "tx_42",
            metadata = mapOf("totalBytes" to "1048576")
        )

        assertEquals(1, captured.size)
        val line = captured[0]
        assertTrue(line.contains("level=INFO"))
        assertTrue(line.contains("subsystem=transfer"))
        assertTrue(line.contains("operation=sendFiles"))
        assertTrue(line.contains("state=connecting"))
        assertTrue(line.contains("correlationId=tx_42"))
        assertTrue(line.contains("totalBytes=\"1048576\""))

        NearsideLogger.logHandler = null
    }

    @Test
    fun testNearsideRedactorPrivacySanitization() {
        val rawPath = "/storage/emulated/0/Download/PrivateConfidential/statement.pdf"
        val cleanPath = NearsideRedactor.sanitizePath(rawPath)
        assertEquals("statement.pdf", cleanPath)
        assertFalse(cleanPath.contains("Download"))

        val rawId = "ns1_8b31f0e2a45c7198bb4d1938fe76d029"
        val cleanId = NearsideRedactor.sanitizeIdentity(rawId)
        assertEquals("ns1_8b31...d029", cleanId)

        val secret = "super_secret_auth_token_value"
        val redacted = NearsideRedactor.redactSecret(secret)
        assertTrue(redacted.contains("REDACTED"))
        assertFalse(redacted.contains("secret"))
    }

    @Test
    fun testTransferRecordDiagnosticFields() {
        val record = TransferRecord(
            deviceName = "MacBook Pro",
            devicePlatform = DevicePlatform.MACOS,
            direction = TransferDirection.INCOMING,
            filename = "archive.tar.gz",
            totalSizeBytes = 2048000,
            correlationId = "tx_rec_1"
        )

        assertNull(record.errorCode)
        assertNull(record.errorMessage)
        assertEquals("tx_rec_1", record.correlationId)

        val failed = record.copy(
            status = TransferStatus.FAILED,
            errorCode = NearsideErrorCode.VERIFY_FILE_CHECKSUM_MISMATCH.code,
            errorMessage = "File checksum mismatch for archive.tar.gz"
        )

        assertEquals(TransferStatus.FAILED, failed.status)
        assertEquals("NS-VERIFY-002", failed.errorCode)
        assertEquals("File checksum mismatch for archive.tar.gz", failed.errorMessage)
        assertEquals("tx_rec_1", failed.correlationId)
    }
}
