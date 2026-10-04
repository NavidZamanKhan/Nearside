import Foundation
import CryptoKit

@main
struct Milestone5Tests {
    static func main() {
        print("==================================================")
        print("  Nearside Milestone 5: iOS Platform Tests")
        print("==================================================")

        testIOSDeviceIdentityAndFingerprint()
        testIOSTrustStoreEnrollmentAndRevocation()
        testIOSQRPairingURICycle()
        testIOSShortCodePakeExchange()
        testIOSShareStagingAndManifest()

        print("==================================================")
        print("  All iOS Milestone 5 Tests PASSED successfully!")
        print("==================================================")
    }

    static func assertCondition(_ condition: Bool, _ message: String) {
        if !condition {
            print("FAILED: \(message)")
            exit(1)
        }
        print("  [PASS] \(message)")
    }

    static func testIOSDeviceIdentityAndFingerprint() {
        print("\n--- Testing iOS DeviceIdentity & Fingerprint ---")
        let identity = DeviceIdentity()
        let fingerprint = identity.publicIdentity

        assertCondition(fingerprint.hasPrefix("ns1_"), "Fingerprint has canonical ns1_ prefix")
        assertCondition(fingerprint.count == 4 + 64, "Fingerprint length is exactly 68 chars (ns1_ + 64 hex chars)")
        assertCondition(!identity.spkiDer.isEmpty, "SPKI DER is non-empty")
    }

    static func testIOSTrustStoreEnrollmentAndRevocation() {
        print("\n--- Testing iOS PinnedTrustStore ---")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("ios_trust.json")
        let trustStore = PinnedTrustStore(customStorageURL: storeURL)

        let peerIdentity = DeviceIdentity()
        assertCondition(!trustStore.isEnrolled(identity: peerIdentity.publicIdentity), "Peer initially not enrolled")

        trustStore.enroll(
            identity: peerIdentity.publicIdentity,
            name: "iPhone 15 Pro",
            platform: "ios",
            publicKey: peerIdentity.publicKey
        )

        assertCondition(trustStore.isEnrolled(identity: peerIdentity.publicIdentity), "Peer enrolled successfully")
        assertCondition(trustStore.allEnrolledPeers().count == 1, "Enrolled count is 1")

        trustStore.unpair(identity: peerIdentity.publicIdentity)
        assertCondition(!trustStore.isEnrolled(identity: peerIdentity.publicIdentity), "Peer successfully unpaired")
    }

    static func testIOSQRPairingURICycle() {
        print("\n--- Testing iOS QR Pairing URI Cycle ---")
        let localIdentity = DeviceIdentity()
        let payload = QRPairingPayload(hostIdentity: localIdentity.publicIdentity, hostName: "iPad Pro", expirySeconds: 120.0)
        let uri = payload.toURI()

        assertCondition(uri.hasPrefix("nearside://pair"), "URI scheme is nearside://pair")

        guard let parsed = QRPairingPayload.fromURI(uri) else {
            assertCondition(false, "Failed to parse pairing URI")
            return
        }

        assertCondition(parsed.sessionId == payload.sessionId, "Session ID matches")
        assertCondition(parsed.hostIdentity == payload.hostIdentity, "Host identity matches")
        assertCondition(parsed.hostName == payload.hostName, "Host name matches")
        assertCondition(parsed.sharedSecretBase64 == payload.sharedSecretBase64, "Shared secret matches")
        assertCondition(!parsed.isExpired, "Parsed payload is not expired")
    }

    static func testIOSShortCodePakeExchange() {
        print("\n--- Testing iOS 8-Digit PAKE Key Agreement ---")
        let code = "58291437"
        let serverIdentity = "ns1_server_identity_ios_11223344"
        let clientIdentity = "ns1_client_identity_ios_55667788"

        let config = PakeSessionConfig(
            shortCode: code,
            serverIdentity: serverIdentity,
            clientIdentity: clientIdentity,
            maxAttempts: 5
        )

        let server = ShortCodePakeParticipant(role: .server, config: config)
        let client = ShortCodePakeParticipant(role: .client, config: config)

        do {
            let serverKeys = try server.computeConfirmationKeys(
                peerEphemeralKey: client.ephemeralPublicKey,
                peerNonce: client.localNonce,
                enteredCode: code
            )
            let clientKeys = try client.computeConfirmationKeys(
                peerEphemeralKey: server.ephemeralPublicKey,
                peerNonce: server.localNonce,
                enteredCode: code
            )

            let serverTranscript = server.buildTranscript(
                remoteEphemeralKey: client.ephemeralPublicKey,
                remoteNonce: client.localNonce
            )
            let clientTranscript = client.buildTranscript(
                remoteEphemeralKey: server.ephemeralPublicKey,
                remoteNonce: server.localNonce
            )

            assertCondition(serverTranscript == clientTranscript, "PAKE transcripts match exactly")

            let serverTag = server.generateConfirmationTag(keys: serverKeys, transcript: serverTranscript)
            let clientTag = client.generateConfirmationTag(keys: clientKeys, transcript: clientTranscript)

            let clientVerify = client.verifyConfirmationTag(peerTag: serverTag, expectedKey: clientKeys.serverKey, transcript: clientTranscript)
            switch clientVerify {
            case .success:
                assertCondition(true, "Client verified server PAKE tag")
            case .failure(let err):
                assertCondition(false, "Client verification failed: \(err)")
            }

            let serverVerify = server.verifyConfirmationTag(peerTag: clientTag, expectedKey: serverKeys.clientKey, transcript: serverTranscript)
            switch serverVerify {
            case .success:
                assertCondition(true, "Server verified client PAKE tag")
            case .failure(let err):
                assertCondition(false, "Server verification failed: \(err)")
            }
        } catch {
            assertCondition(false, "PAKE confirmation threw exception: \(error)")
        }
    }

    static func testIOSShareStagingAndManifest() {
        print("\n--- Testing iOS Share Staging & Chunk Framing ---")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create 2 staged files (photos / documents)
        let fileA = tempDir.appendingPathComponent("Photo_01.jpg")
        let fileB = tempDir.appendingPathComponent("Notes.pdf")
        let dataA = Data((0..<65536).map { UInt8($0 % 255) })
        let dataB = Data((0..<32768).map { UInt8(($0 * 2) % 255) })
        try! dataA.write(to: fileA)
        try! dataB.write(to: fileB)

        let engine = TransferEngine()
        let manifest: TransferManifest
        do {
            let res = try engine.buildManifest(for: [fileA, fileB], senderId: "ns1_sender_ios")
            manifest = res.manifest
            for h in res.fileHandles { try? h.close() }
        } catch {
            assertCondition(false, "Failed to build manifest: \(error)")
            return
        }

        assertCondition(manifest.itemCount == 2, "Manifest item count is 2")
        assertCondition(manifest.totalBytes == Int64(dataA.count + dataB.count), "Manifest total bytes matches exact file sizes")

        let chunk = TransferChunk(itemIndex: 0, offset: 0, data: dataA)
        let encoded = chunk.encode()
        guard let (decoded, consumed) = TransferChunk.decode(from: encoded) else {
            assertCondition(false, "Failed to decode chunk")
            return
        }

        assertCondition(consumed == encoded.count, "Consumed byte count matches")
        assertCondition(decoded.data == dataA, "Decoded chunk data matches staged photo bytes")
    }
}
