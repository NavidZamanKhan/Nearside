import Foundation
import CryptoKit

public enum DiagnosticTests {
    public static func runAll() {
        print("==================================================")
        print("  Nearside: Central Diagnostic Foundation Tests")
        print("==================================================")

        testErrorCodeRegistryFormat()
        testNearsideErrorPreservesNativeCause()
        testNearsideLoggerStructuredOutput()
        testNearsideRedactorPrivacyGuarantees()
        testTransferEngineErrorDiagnosticMapping()
        testPairingAndPakeErrorDiagnosticMapping()
        testTransferRecordDiagnosticFields()

        print("==================================================")
        print("  All Diagnostic Foundation Tests PASSED!")
        print("==================================================")
    }

    private static func assert(_ condition: Bool, _ message: String) {
        if !condition {
            print("FAILED: \(message)")
            exit(1)
        }
        print("  [PASS] \(message)")
    }

    // 1. Error Code Registry Format
    static func testErrorCodeRegistryFormat() {
        print("\n--- Testing Error Code Registry Format ---")
        let regex = try! NSRegularExpression(pattern: "^NS-[A-Z]+-[0-9]{3}$")

        for code in NearsideErrorCode.allCases {
            let str = code.rawValue
            let range = NSRange(location: 0, length: str.utf16.count)
            let matches = regex.matches(in: str, range: range)
            assert(!matches.isEmpty, "Error code \(str) adheres to NS-[SUBSYSTEM]-[NUMBER] format")
            assert(!code.subsystem.isEmpty, "Error code \(str) maps to valid subsystem: \(code.subsystem)")
        }
    }

    // 2. Underlying Native Error Retention
    static func testNearsideErrorPreservesNativeCause() {
        print("\n--- Testing Native Error Cause Retention ---")
        let nativeError = NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT), userInfo: [NSLocalizedDescriptionKey: "Connection timed out"])
        let nearsideErr = NearsideError(
            code: .connectionTimedOut,
            operation: "connectSocket",
            message: "Peer connection timed out after 15s",
            underlyingError: nativeError,
            correlationId: "tx_abc123",
            retryCount: 2
        )

        assert(nearsideErr.code == .connectionTimedOut, "Preserves Nearside error code")
        assert(nearsideErr.subsystem == "connection", "Derives subsystem correctly")
        assert(nearsideErr.correlationId == "tx_abc123", "Preserves correlation ID")
        assert(nearsideErr.retryCount == 2, "Preserves retry count")
        assert(nearsideErr.underlyingErrorDescription?.contains("ETIMEDOUT") == true || nearsideErr.underlyingErrorDescription?.contains("Connection timed out") == true, "Preserves native error description")

        let desc = nearsideErr.description
        assert(desc.contains("code=NS-CONN-001"), "Description includes error code")
        assert(desc.contains("correlationId=tx_abc123"), "Description includes correlation ID")
    }

    // 3. Structured Logging
    static func testNearsideLoggerStructuredOutput() {
        print("\n--- Testing NearsideLogger Structured Formatting ---")
        var loggedLines: [String] = []
        NearsideLogger.shared.logHandler = { line in
            loggedLines.append(line)
        }

        NearsideLogger.shared.info(
            "transfer",
            "sendFiles",
            "Starting outbound transfer",
            state: "connecting",
            correlationId: "tx_999",
            metadata: ["totalBytes": "524288"]
        )

        assert(loggedLines.count == 1, "Logger intercepted exactly one line")
        let line = loggedLines[0]
        assert(line.contains("level=INFO"), "Log line contains level")
        assert(line.contains("subsystem=transfer"), "Log line contains subsystem")
        assert(line.contains("operation=sendFiles"), "Log line contains operation")
        assert(line.contains("state=connecting"), "Log line contains state")
        assert(line.contains("correlationId=tx_999"), "Log line contains correlationId")
        assert(line.contains("totalBytes=\"524288\""), "Log line contains metadata")

        NearsideLogger.shared.logHandler = nil
    }

    // 4. Privacy Redactor
    static func testNearsideRedactorPrivacyGuarantees() {
        print("\n--- Testing NearsideRedactor Privacy Sanitization ---")
        let fullPath = "/Users/username/SecretDocuments/Finances/tax_return_2025.pdf"
        let cleanPath = NearsideRedactor.sanitizePath(fullPath)
        assert(cleanPath == "tax_return_2025.pdf", "Path sanitized to basename: \(cleanPath)")
        assert(!cleanPath.contains("username"), "Username stripped from sanitized path")

        let fullId = "ns1_8b31f0e2a45c7198bb4d1938fe76d029"
        let cleanId = NearsideRedactor.sanitizeIdentity(fullId)
        assert(cleanId == "ns1_8b31...d029", "Device identity truncated: \(cleanId)")

        let secret = "very_sensitive_pairing_secret_key"
        let redacted = NearsideRedactor.redactSecret(secret)
        assert(!redacted.contains("secret"), "Secret redacted from output: \(redacted)")
        assert(redacted.contains("REDACTED"), "Contains redaction marker")
    }

    // 5. TransferEngineError to NearsideError Mapping
    static func testTransferEngineErrorDiagnosticMapping() {
        print("\n--- Testing TransferEngineError Mapping ---")
        let connErr = TransferEngineError.connectionFailed("Host unreachable").toNearsideError(correlationId: "tx_1")
        assert(connErr.code == .connectionTimedOut, "connectionFailed maps to NS-CONN-001")

        let trustErr = TransferEngineError.untrustedPeer("ns1_abc").toNearsideError(correlationId: "tx_2")
        assert(trustErr.code == .trustUntrustedPeer, "untrustedPeer maps to NS-TRUST-001")

        let rejErr = TransferEngineError.manifestRejected("Disk full").toNearsideError(correlationId: "tx_3")
        assert(rejErr.code == .transferRejected, "manifestRejected maps to NS-TRANSFER-002")

        let intErr = TransferEngineError.integrityMismatch("sample.bin").toNearsideError(correlationId: "tx_4")
        assert(intErr.code == .verifyFileChecksumMismatch, "integrityMismatch maps to NS-VERIFY-002")

        let storErr = TransferEngineError.fileAccessError("Permission denied").toNearsideError(correlationId: "tx_5")
        assert(storErr.code == .storageReadFailed, "fileAccessError maps to NS-STORAGE-001")

        let cancErr = TransferEngineError.cancelled.toNearsideError(correlationId: "tx_6")
        assert(cancErr.code == .transferCancelled, "cancelled maps to NS-TRANSFER-004")
    }

    // 6. Pairing & PAKE Error Diagnostic Mapping
    static func testPairingAndPakeErrorDiagnosticMapping() {
        print("\n--- Testing Pairing & PAKE Error Mapping ---")
        let pairExpired = PairingError.sessionExpired.toNearsideError(correlationId: "pair_1")
        assert(pairExpired.code == .pairingSessionExpired, "sessionExpired maps to NS-PAIR-001")

        let pairFailed = PairingError.verificationFailed.toNearsideError(correlationId: "pair_2")
        assert(pairFailed.code == .pairingVerificationFailed, "verificationFailed maps to NS-PAIR-002")

        let pakeLockout = PakeError.maxAttemptsExceeded.toNearsideError(correlationId: "pake_1")
        assert(pakeLockout.code == .pairingRateLimitExceeded, "maxAttemptsExceeded maps to NS-PAIR-003")

        let pakeMismatch = PakeError.tagMismatch(attemptsRemaining: 2).toNearsideError(correlationId: "pake_2")
        assert(pakeMismatch.code == .pairingVerificationFailed, "tagMismatch maps to NS-PAIR-002")
    }

    // 7. TransferRecord Diagnostic Fields
    static func testTransferRecordDiagnosticFields() {
        print("\n--- Testing TransferRecord Diagnostic Fields ---")
        var record = TransferRecord(
            deviceName: "Android Device",
            devicePlatform: .android,
            direction: .incoming,
            filename: "photo.jpg",
            totalSizeBytes: 1048576,
            correlationId: "tx_test_42"
        )

        assert(record.errorCode == nil, "Initial errorCode is nil")
        assert(record.errorMessage == nil, "Initial errorMessage is nil")
        assert(record.correlationId == "tx_test_42", "Retains correlationId")

        record.status = .failed
        record.errorCode = NearsideErrorCode.verifyFileChecksumMismatch.rawValue
        record.errorMessage = "Checksum mismatch for photo.jpg"

        assert(record.status == .failed, "Status transitioned to failed")
        assert(record.errorCode == "NS-VERIFY-002", "Attached canonical error code NS-VERIFY-002")
        assert(record.errorMessage?.contains("Checksum mismatch") == true, "Attached diagnostic error message")
    }
}

#if !TESTING_STANDALONE
@main
struct DiagnosticTestsRunner {
    static func main() {
        DiagnosticTests.runAll()
    }
}
#endif
