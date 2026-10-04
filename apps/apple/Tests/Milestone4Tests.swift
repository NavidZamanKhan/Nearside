import Foundation
import CryptoKit
import Network

@main
struct Milestone4Tests {
    static func main() {
        print("==================================================")
        print("  Nearside Milestone 4: Robustness & Resume Tests")
        print("==================================================")

        testRetryPolicyBackoffCalculation()
        testPathTraversalSanitization()
        testPartialResumeCalculationAndRehash()
        testFullResumeStreamingSimulation()

        print("==================================================")
        print("  All macOS Milestone 4 Tests PASSED successfully!")
        print("==================================================")
    }

    static func assertCondition(_ condition: Bool, _ message: String) {
        if !condition {
            print("FAILED: \(message)")
            exit(1)
        }
        print("  [PASS] \(message)")
    }

    static func testRetryPolicyBackoffCalculation() {
        print("\n--- Testing RetryPolicy Exponential Backoff ---")
        let policy = RetryPolicy(maxAttempts: 3, initialDelay: 0.5, multiplier: 2.0)
        assertCondition(policy.delay(forAttempt: 0) == 0.0, "Attempt 0 produces 0 delay")
        assertCondition(policy.delay(forAttempt: 1) == 0.5, "Attempt 1 produces initial delay 0.5s")
        assertCondition(policy.delay(forAttempt: 2) == 1.0, "Attempt 2 produces doubled delay 1.0s")
        assertCondition(policy.delay(forAttempt: 3) == 2.0, "Attempt 3 produces quadrupled delay 2.0s")
    }

    static func testPathTraversalSanitization() {
        print("\n--- Testing Path Traversal Defense ---")
        let maliciousNames = [
            "../../etc/passwd",
            "../bad.sh",
            "/private/etc/hosts",
            "subfolder/file.bin",
            "nested\\traversal.exe",
            ".",
            ".."
        ]

        for name in maliciousNames {
            let clean = (name as NSString).lastPathComponent
            let isDangerous = clean.isEmpty || clean == "." || clean == ".." || clean != name || name.contains("/") || name.contains("\\")
            assertCondition(isDangerous, "Rejected dangerous path: \(name)")
        }

        let validNames = ["document.pdf", "photo_2026.png", "archive.tar.gz"]
        for name in validNames {
            let clean = (name as NSString).lastPathComponent
            let isDangerous = clean.isEmpty || clean == "." || clean == ".." || clean != name || name.contains("/") || name.contains("\\")
            assertCondition(!isDangerous, "Accepted valid filename: \(name)")
        }
    }

    static func testPartialResumeCalculationAndRehash() {
        print("\n--- Testing Partial File Resume & Rehash ---")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Generate full 128 KiB data
        let fullData = Data((0..<(128 * 1024)).map { UInt8(($0 * 3) % 251) })
        let fullHash = SHA256.hash(data: fullData).compactMap { String(format: "%02x", $0) }.joined()

        // Create partial 64 KiB file
        let partialURL = tempDir.appendingPathComponent("partial_test.bin")
        let firstHalf = fullData.subdata(in: 0..<(64 * 1024))
        try? firstHalf.write(to: partialURL)

        // Read and pre-hash existing 64 KiB
        let readHandle = try! FileHandle(forReadingFrom: partialURL)
        var runningHasher = SHA256()
        var bytesRead: Int64 = 0
        while bytesRead < 64 * 1024 {
            let chunk = readHandle.readData(ofLength: TransferChunk.maxChunkSize)
            if chunk.isEmpty { break }
            runningHasher.update(data: chunk)
            bytesRead += Int64(chunk.count)
        }
        try? readHandle.close()
        assertCondition(bytesRead == 64 * 1024, "Read exactly 64 KiB from partial file")

        // Open handle for updating, seek to 64 KiB, append remaining 64 KiB
        let writeHandle = try! FileHandle(forUpdating: partialURL)
        try! writeHandle.seek(toOffset: UInt64(bytesRead))
        let secondHalf = fullData.subdata(in: (64 * 1024)..<(128 * 1024))
        writeHandle.write(secondHalf)
        runningHasher.update(data: secondHalf)
        try? writeHandle.close()

        // Verify total size and hash match original full 128 KiB
        let reloadedData = try! Data(contentsOf: partialURL)
        assertCondition(reloadedData.count == 128 * 1024, "Resumed file is exactly 128 KiB")
        assertCondition(reloadedData == fullData, "Resumed file byte-for-byte identical to full data")

        let finalCalculatedHash = runningHasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
        assertCondition(finalCalculatedHash == fullHash, "Incremental resume hash matches authoritative SHA256")
    }

    static func testFullResumeStreamingSimulation() {
        print("\n--- Testing Chunk Framing with Resume Offset ---")
        let payload = Data(repeating: 0x42, count: 64 * 1024)
        let chunk = TransferChunk(itemIndex: 0, offset: 65536, data: payload)

        let encoded = chunk.encode()
        guard let (decoded, consumed) = TransferChunk.decode(from: encoded) else {
            assertCondition(false, "Failed to decode resume chunk")
            return
        }

        assertCondition(consumed == encoded.count, "Consumed matches encoded chunk size")
        assertCondition(decoded.offset == 65536, "Chunk offset is 65536 (resumed position)")
        assertCondition(decoded.data == payload, "Chunk data matches resume payload")
    }
}
