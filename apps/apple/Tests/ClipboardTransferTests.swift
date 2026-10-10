import Foundation
import CryptoKit
import Network

@main
struct ClipboardTransferTests {
    static func main() {
        print("==================================================")
        print("  Nearside: Clipboard & Instant Content Tests")
        print("==================================================")

        testBuildTextManifestForPlainText()
        testBuildTextManifestForURL()
        testTransferRecordPayloadProperties()
        testLoopbackClipboardTransfer()
        testLoopbackUrlTransfer()

        print("==================================================")
        print("  All Clipboard & Instant Content Tests PASSED!")
        print("==================================================")
    }

    static func assertCondition(_ condition: Bool, _ message: String) {
        if !condition {
            print("FAILED: \(message)")
            exit(1)
        }
        print("  [PASS] \(message)")
    }

    static func testBuildTextManifestForPlainText() {
        print("\n--- Testing Plain Text Manifest Generation ---")
        let text = "Hello from Nearside instant clipboard sharing!"
        let (manifest, data) = TransferManifest.buildTextManifest(
            text: text,
            isURL: false,
            senderId: "ns1_test_sender_123"
        )

        assertCondition(manifest.itemCount == 1, "Item count is 1")
        assertCondition(manifest.totalBytes == Int64(data.count), "Total bytes equals data count")
        assertCondition(manifest.items[0].name == "clipboard.txt", "Item name is clipboard.txt")
        assertCondition(manifest.items[0].mimeType == "text/plain", "MIME type is text/plain")

        let expectedSha = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        assertCondition(manifest.items[0].sha256 == expectedSha, "SHA-256 matches expected content hash")
    }

    static func testBuildTextManifestForURL() {
        print("\n--- Testing URL Manifest Generation ---")
        let urlString = "https://github.com/NavidZamanKhan/Nearside"
        let (manifest, data) = TransferManifest.buildTextManifest(
            text: urlString,
            isURL: true,
            senderId: "ns1_test_sender_123"
        )

        assertCondition(manifest.itemCount == 1, "Item count is 1")
        assertCondition(manifest.totalBytes == Int64(data.count), "Total bytes equals URL byte count")
        assertCondition(manifest.items[0].name == "link.url", "Item name is link.url")
        assertCondition(manifest.items[0].mimeType == "text/uri-list", "MIME type is text/uri-list")

        let expectedSha = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        assertCondition(manifest.items[0].sha256 == expectedSha, "SHA-256 matches URL hash")
    }

    static func testTransferRecordPayloadProperties() {
        print("\n--- Testing TransferRecord Payload Types ---")
        let textRecord = TransferRecord(
            deviceName: "Pixel 9 Pro",
            devicePlatform: .android,
            direction: .incoming,
            filename: "clipboard.txt",
            totalSizeBytes: 42,
            payloadType: .text,
            payloadText: "Sample clipboard text snippet"
        )
        assertCondition(textRecord.payloadType == .text, "Payload type is text")
        assertCondition(textRecord.payloadText == "Sample clipboard text snippet", "Payload text matches")

        let urlRecord = TransferRecord(
            deviceName: "iPhone 16 Pro",
            devicePlatform: .iOS,
            direction: .outgoing,
            filename: "link.url",
            totalSizeBytes: 30,
            payloadType: .url,
            payloadText: "https://apple.com"
        )
        assertCondition(urlRecord.payloadType == .url, "Payload type is url")
        assertCondition(urlRecord.payloadText == "https://apple.com", "Payload text matches URL")
    }

    static func testLoopbackClipboardTransfer() {
        print("\n--- Testing Loopback TCP Clipboard Transfer ---")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("nearside_cb_rx_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let senderIdentity = DeviceIdentity()
        let receiverIdentity = DeviceIdentity()
        let rxStoreURL = tempDir.appendingPathComponent("rx_trust_store.json")
        let rxTrustStore = PinnedTrustStore(customStorageURL: rxStoreURL)
        rxTrustStore.enroll(
            identity: senderIdentity.publicIdentity,
            name: "Loopback Sender",
            platform: "macos",
            publicKey: senderIdentity.publicKey
        )

        let txStoreURL = tempDir.appendingPathComponent("tx_trust_store.json")
        let txTrustStore = PinnedTrustStore(customStorageURL: txStoreURL)
        txTrustStore.enroll(
            identity: receiverIdentity.publicIdentity,
            name: "Loopback Receiver",
            platform: "macos",
            publicKey: receiverIdentity.publicKey
        )

        let port: UInt16 = 42561
        let listenerParams = NWParameters.tcp
        listenerParams.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(using: listenerParams, on: NWEndpoint.Port(rawValue: port)!) else {
            assertCondition(false, "Failed to bind loopback test listener")
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        var receivedRecord: TransferRecord?

        listener.newConnectionHandler = { connection in
            TransferEngine.shared.handleInboundConnection(
                connection: connection,
                trustStore: rxTrustStore,
                deviceIdentity: receiverIdentity,
                destinationFolder: tempDir,
                onProgress: { _, _ in },
                onComplete: { result in
                    switch result {
                    case .success(let record):
                        receivedRecord = record
                    case .failure(let err):
                        print("Inbound failure: \(err)")
                    }
                    semaphore.signal()
                }
            )
        }
        listener.start(queue: .global())

        let device = NearsideDevice(
            id: receiverIdentity.publicIdentity,
            name: "Loopback Receiver",
            platform: .macOS,
            fingerprint: receiverIdentity.publicIdentity,
            ipAddress: "127.0.0.1",
            port: port
        )

        let textToSend = "Beamed from macOS directly via local socket!"
        let clientSem = DispatchSemaphore(value: 0)
        var sendSuccess = false

        TransferEngine.shared.sendText(
            text: textToSend,
            isURL: false,
            to: device,
            senderId: senderIdentity.publicIdentity,
            trustStore: txTrustStore,
            deviceIdentity: senderIdentity,
            onProgress: { _, _, _ in },
            completion: { result in
                switch result {
                case .success:
                    sendSuccess = true
                case .failure(let err):
                    print("Send failure: \(err)")
                }
                clientSem.signal()
            }
        )

        _ = clientSem.wait(timeout: .now() + 5.0)
        _ = semaphore.wait(timeout: .now() + 5.0)
        listener.cancel()

        assertCondition(sendSuccess, "SendText completed successfully over loopback")
        assertCondition(receivedRecord != nil, "Inbound receiver processed transfer")
        assertCondition(receivedRecord?.status == .completed, "Inbound transfer status is completed")
        assertCondition(receivedRecord?.payloadType == .text, "Inbound payload type is recognized as text")
        assertCondition(receivedRecord?.payloadText == textToSend, "Inbound payload text matches sent text")
    }

    static func testLoopbackUrlTransfer() {
        print("\n--- Testing Loopback TCP URL Transfer ---")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("nearside_url_rx_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let senderIdentity = DeviceIdentity()
        let receiverIdentity = DeviceIdentity()
        let rxStoreURL = tempDir.appendingPathComponent("rx_trust_store.json")
        let rxTrustStore = PinnedTrustStore(customStorageURL: rxStoreURL)
        rxTrustStore.enroll(
            identity: senderIdentity.publicIdentity,
            name: "Loopback Sender",
            platform: "macos",
            publicKey: senderIdentity.publicKey
        )

        let txStoreURL = tempDir.appendingPathComponent("tx_trust_store.json")
        let txTrustStore = PinnedTrustStore(customStorageURL: txStoreURL)
        txTrustStore.enroll(
            identity: receiverIdentity.publicIdentity,
            name: "Loopback Receiver",
            platform: "macos",
            publicKey: receiverIdentity.publicKey
        )

        let port: UInt16 = 42562
        let listenerParams = NWParameters.tcp
        listenerParams.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(using: listenerParams, on: NWEndpoint.Port(rawValue: port)!) else {
            assertCondition(false, "Failed to bind loopback test listener")
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        var receivedRecord: TransferRecord?

        listener.newConnectionHandler = { connection in
            TransferEngine.shared.handleInboundConnection(
                connection: connection,
                trustStore: rxTrustStore,
                deviceIdentity: receiverIdentity,
                destinationFolder: tempDir,
                onProgress: { _, _ in },
                onComplete: { result in
                    switch result {
                    case .success(let record):
                        receivedRecord = record
                    case .failure(let err):
                        print("Inbound failure: \(err)")
                    }
                    semaphore.signal()
                }
            )
        }
        listener.start(queue: .global())

        let device = NearsideDevice(
            id: receiverIdentity.publicIdentity,
            name: "Loopback Receiver",
            platform: .macOS,
            fingerprint: receiverIdentity.publicIdentity,
            ipAddress: "127.0.0.1",
            port: port
        )

        let urlToSend = "https://nearside.local/beam/v1"
        let clientSem = DispatchSemaphore(value: 0)
        var sendSuccess = false

        TransferEngine.shared.sendText(
            text: urlToSend,
            isURL: true,
            to: device,
            senderId: senderIdentity.publicIdentity,
            trustStore: txTrustStore,
            deviceIdentity: senderIdentity,
            onProgress: { _, _, _ in },
            completion: { result in
                switch result {
                case .success:
                    sendSuccess = true
                case .failure(let err):
                    print("Send failure: \(err)")
                }
                clientSem.signal()
            }
        )

        _ = clientSem.wait(timeout: .now() + 5.0)
        _ = semaphore.wait(timeout: .now() + 5.0)
        listener.cancel()

        assertCondition(sendSuccess, "SendText completed successfully over loopback for URL")
        assertCondition(receivedRecord != nil, "Inbound receiver processed URL transfer")
        assertCondition(receivedRecord?.status == .completed, "Inbound URL transfer status is completed")
        assertCondition(receivedRecord?.payloadType == .url, "Inbound payload type is recognized as url")
        assertCondition(receivedRecord?.payloadText == urlToSend, "Inbound payload text matches sent URL")
    }
}
