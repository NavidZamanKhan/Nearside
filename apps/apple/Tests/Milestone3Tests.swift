import Foundation
import CryptoKit
import Network

@main
struct Milestone3Tests {
    static func main() {
        print("==================================================")
        print("  Nearside Milestone 3: macOS Transfer Engine Tests")
        print("==================================================")

        testManifestEncoding()
        testAckEncoding()
        testErrorFrameEncoding()
        testChunkEncodingDecoding()
        testChunkTamperDetection()
        testLoopbackTransfer()

        print("==================================================")
        print("  All macOS Milestone 3 Tests PASSED successfully!")
        print("==================================================")
    }

    static func assertCondition(_ condition: Bool, _ message: String) {
        if !condition {
            print("FAILED: \(message)")
            exit(1)
        }
        print("  [PASS] \(message)")
    }

    static func testManifestEncoding() {
        print("\n--- Testing Manifest Encoding & Parsing ---")
        let item = TransferItemManifest(
            index: 0,
            name: "test_doc.pdf",
            mimeType: "application/pdf",
            size: 1048576,
            sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        let manifest = TransferManifest(
            transferId: "tx_test_123456",
            senderId: "ns1_sender_identity_123",
            items: [item]
        )

        assertCondition(manifest.totalBytes == 1048576, "Manifest computes total bytes correctly")
        assertCondition(manifest.itemCount == 1, "Item count is 1")

        guard let encoded = try? JSONEncoder().encode(manifest),
              let decoded = try? JSONDecoder().decode(TransferManifest.self, from: encoded) else {
            assertCondition(false, "Failed to encode/decode manifest")
            return
        }

        assertCondition(decoded == manifest, "Decoded manifest matches original exactly")
    }

    static func testAckEncoding() {
        print("\n--- Testing TransferAck Encoding ---")
        let ack = TransferAck(
            transferId: "tx_test_123456",
            status: "ACCEPTED",
            acceptedItems: [0],
            bytesReceived: 0,
            readyForStream: true
        )

        guard let encoded = try? JSONEncoder().encode(ack),
              let decoded = try? JSONDecoder().decode(TransferAck.self, from: encoded) else {
            assertCondition(false, "Failed to encode/decode TransferAck")
            return
        }

        assertCondition(decoded == ack, "Decoded TransferAck matches original")
    }

    static func testErrorFrameEncoding() {
        print("\n--- Testing ErrorFrame Encoding ---")
        let err = ErrorFrame(code: 403, reason: "DEVICE_NOT_PAIRED", detail: "Untrusted sender")
        guard let encoded = try? JSONEncoder().encode(err),
              let decoded = try? JSONDecoder().decode(ErrorFrame.self, from: encoded) else {
            assertCondition(false, "Failed to encode/decode ErrorFrame")
            return
        }
        assertCondition(decoded == err, "Decoded ErrorFrame matches original")
    }

    static func testChunkEncodingDecoding() {
        print("\n--- Testing Chunk Framing (64 KiB Bounded) ---")
        let rawPayload = Data((0..<32768).map { UInt8($0 % 256) })
        let chunk = TransferChunk(itemIndex: 0, offset: 65536, data: rawPayload)

        assertCondition(chunk.sha256Hex.count == 64, "Chunk SHA256 hex is 64 characters")

        let encoded = chunk.encode()
        assertCondition(encoded.count == 21 + rawPayload.count + 32, "Encoded packet length is exact header + data + hash")

        guard let (decoded, consumed) = TransferChunk.decode(from: encoded) else {
            assertCondition(false, "Failed to decode valid chunk packet")
            return
        }

        assertCondition(consumed == encoded.count, "Consumed byte count matches packet size")
        assertCondition(decoded.itemIndex == 0, "Decoded itemIndex matches")
        assertCondition(decoded.offset == 65536, "Decoded offset matches")
        assertCondition(decoded.data == rawPayload, "Decoded payload data matches original")
        assertCondition(decoded.sha256Hex == chunk.sha256Hex, "Decoded chunk hash matches")
    }

    static func testChunkTamperDetection() {
        print("\n--- Testing Chunk Tamper Detection ---")
        let rawPayload = "NearsideChunkDataToProtect".data(using: .utf8)!
        let chunk = TransferChunk(itemIndex: 1, offset: 0, data: rawPayload)
        var encoded = chunk.encode()

        // Tamper with payload byte
        encoded[25] ^= 0xFF
        let result = TransferChunk.decode(from: encoded)
        assertCondition(result == nil, "Chunk decoder rejected tampered payload")

        // Tamper with magic bytes
        var badMagic = chunk.encode()
        badMagic[0] = 0x00
        let badMagicResult = TransferChunk.decode(from: badMagic)
        assertCondition(badMagicResult == nil, "Chunk decoder rejected bad magic")
    }

    static func testLoopbackTransfer() {
        print("\n--- Testing Loopback TransferEngine ---")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloadDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)

        let testFile = tempDir.appendingPathComponent("transfer_test.bin")
        let testData = Data((0..<(128 * 1024)).map { UInt8($0 % 251) })
        try? testData.write(to: testFile)

        let engine = TransferEngine()
        let manifest: TransferManifest
        do {
            let res = try engine.buildManifest(for: [testFile], senderId: "ns1_test_mac_sender")
            manifest = res.manifest
            for h in res.fileHandles { try? h.close() }
        } catch {
            assertCondition(false, "Failed to build manifest: \(error)")
            return
        }

        assertCondition(manifest.totalBytes == Int64(testData.count), "Manifest size matches created file size")
        assertCondition(manifest.items.count == 1, "Manifest item count is 1")

        let expectedHash = SHA256.hash(data: testData).compactMap { String(format: "%02x", $0) }.joined()
        assertCondition(manifest.items[0].sha256 == expectedHash, "Manifest item SHA256 matches exact data hash")
    }
}
