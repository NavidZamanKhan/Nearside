import Foundation
import CryptoKit
import Network

@main
struct Milestone2Tests {
    static func main() {
        print("==================================================")
        print("  Nearside Milestone 2: macOS Discovery & Pairing Tests")
        print("==================================================")

        testDeviceIdentity()
        testPinnedTrustStore()
        testQRPairingProtocol()
        testShortCodePakeProtocol()
        testDiscoveryServiceBasics()

        print("==================================================")
        print("  All macOS Milestone 2 Tests PASSED successfully!")
        print("==================================================")
    }

    static func assertCondition(_ condition: Bool, _ message: String) {
        if !condition {
            print("FAILED: \(message)")
            exit(1)
        }
        print("  [PASS] \(message)")
    }

    static func testDeviceIdentity() {
        print("\n--- Testing DeviceIdentity ---")
        let identity = DeviceIdentity()
        assertCondition(identity.publicIdentity.hasPrefix("ns1_"), "Public identity starts with ns1_")
        assertCondition(identity.publicIdentity.count == 4 + 64, "Public identity is ns1_ followed by 64-char SHA256 hex string")
        assertCondition(!identity.spkiDer.isEmpty, "SPKI DER representation is non-empty")

        // Test sign and verify
        let message = "TestNearsideData".data(using: .utf8)!
        do {
            let sig = try identity.sign(data: message)
            assertCondition(!sig.isEmpty, "Generated valid signature")
            let isValid = DeviceIdentity.verify(signature: sig, for: message, publicKey: identity.publicKey)
            assertCondition(isValid, "Verified valid signature")

            let tampered = "TamperedNearsideData".data(using: .utf8)!
            let isInvalid = DeviceIdentity.verify(signature: sig, for: tampered, publicKey: identity.publicKey)
            assertCondition(!isInvalid, "Rejected tampered message signature")
        } catch {
            assertCondition(false, "Signing threw exception: \(error)")
        }
    }

    static func testPinnedTrustStore() {
        print("\n--- Testing PinnedTrustStore ---")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storeURL = tempDir.appendingPathComponent("test_trust_store.json")

        let store = PinnedTrustStore(customStorageURL: storeURL)
        let peerKey = P256.Signing.PrivateKey().publicKey
        let peerSpki = peerKey.derRepresentation
        let peerId = DeviceIdentity.computeIdentity(fromSpki: peerSpki)

        // 1. Untrusted initially
        let initialRes = store.validatePeer(presentedSpki: peerSpki)
        assertCondition(initialRes == .failure(.untrustedPeer(identity: peerId)), "Unknown peer is untrusted")

        // 2. Enroll
        store.enroll(identity: peerId, name: "Test Android", platform: "android", publicKey: peerKey)
        assertCondition(store.isEnrolled(identity: peerId), "Peer is now enrolled")
        let enrolledRes = store.validatePeer(presentedSpki: peerSpki)
        assertCondition(enrolledRes == .success(peerId), "Enrolled peer validates successfully")

        // 3. Block
        store.block(identity: peerId)
        let blockedRes = store.validatePeer(presentedSpki: peerSpki)
        assertCondition(blockedRes == .failure(.peerBlocked(identity: peerId)), "Blocked peer is rejected")

        // 4. Unpair
        store.unpair(identity: peerId)
        assertCondition(!store.isEnrolled(identity: peerId), "Unpaired peer is no longer enrolled")
    }

    static func testQRPairingProtocol() {
        print("\n--- Testing QRPairingProtocol ---")
        let hostIdentity = DeviceIdentity()
        let clientIdentity = DeviceIdentity()

        let payload = QRPairingPayload(hostIdentity: hostIdentity.publicIdentity, hostName: "MacBook Pro")
        assertCondition(!payload.isExpired, "New payload is not expired")

        let uri = payload.toURI()
        assertCondition(uri.hasPrefix("nearside://pair?"), "URI starts with nearside://pair?")

        guard let parsed = QRPairingPayload.fromURI(uri) else {
            assertCondition(false, "Failed to parse URI back to payload")
            return
        }
        assertCondition(parsed.sessionId == payload.sessionId, "Parsed sessionId matches original")
        assertCondition(parsed.hostIdentity == payload.hostIdentity, "Parsed hostIdentity matches original")
        assertCondition(parsed.sharedSecretBase64 == payload.sharedSecretBase64, "Parsed secret matches original")

        // Test mutual confirmation
        let hostSession = QRPairingSession(role: .host, localIdentity: hostIdentity, payload: payload)
        let clientSession = QRPairingSession(role: .client, localIdentity: clientIdentity, payload: parsed)

        let hostTranscript = hostSession.buildTranscript(
            remoteNonce: clientSession.localNonce,
            clientIdentity: clientIdentity.publicIdentity,
            serverIdentity: hostIdentity.publicIdentity
        )

        let clientTranscript = clientSession.buildTranscript(
            remoteNonce: hostSession.localNonce,
            clientIdentity: clientIdentity.publicIdentity,
            serverIdentity: hostIdentity.publicIdentity
        )

        assertCondition(hostTranscript == clientTranscript, "Transcripts match symmetrically")

        do {
            let hostKeys = try hostSession.deriveConfirmationKeys(transcript: hostTranscript)
            let clientKeys = try clientSession.deriveConfirmationKeys(transcript: clientTranscript)

            let hostConfirm = hostSession.generateConfirmation(keys: hostKeys, transcript: hostTranscript)
            let clientConfirm = clientSession.generateConfirmation(keys: clientKeys, transcript: clientTranscript)

            let clientVerifiedHost = clientSession.verifyPeerConfirmation(
                peerMac: hostConfirm,
                expectedKey: clientKeys.serverKey,
                transcript: clientTranscript
            )
            assertCondition(clientVerifiedHost, "Client verified host confirmation MAC")

            let hostVerifiedClient = hostSession.verifyPeerConfirmation(
                peerMac: clientConfirm,
                expectedKey: hostKeys.clientKey,
                transcript: hostTranscript
            )
            assertCondition(hostVerifiedClient, "Host verified client confirmation MAC")

            // Tampered MAC fails
            var tamperedMac = clientConfirm
            tamperedMac[0] ^= 0xFF
            let rejectedTampered = hostSession.verifyPeerConfirmation(
                peerMac: tamperedMac,
                expectedKey: hostKeys.clientKey,
                transcript: hostTranscript
            )
            assertCondition(!rejectedTampered, "Host rejected tampered confirmation MAC")
        } catch {
            assertCondition(false, "Key derivation threw: \(error)")
        }
    }

    static func testShortCodePakeProtocol() {
        print("\n--- Testing ShortCodePakeProtocol ---")
        let correctCode = "48192034"
        let wrongCode = "99999999"
        let serverId = "ns1_server_identity_hash_here_11223344"
        let clientId = "ns1_client_identity_hash_here_55667788"

        let config = PakeSessionConfig(shortCode: correctCode, serverIdentity: serverId, clientIdentity: clientId, maxAttempts: 5)
        let server = ShortCodePakeParticipant(role: .server, config: config)
        let client = ShortCodePakeParticipant(role: .client, config: config)

        // Succeeded handshake with correct code
        do {
            let serverKeys = try server.computeConfirmationKeys(
                peerEphemeralKey: client.ephemeralPublicKey,
                peerNonce: client.localNonce,
                enteredCode: correctCode
            )
            let clientKeys = try client.computeConfirmationKeys(
                peerEphemeralKey: server.ephemeralPublicKey,
                peerNonce: server.localNonce,
                enteredCode: correctCode
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
            assertCondition(false, "PAKE compute confirmation threw: \(error)")
        }

        // Test wrong code and lockout
        let attackServer = ShortCodePakeParticipant(role: .server, config: config)
        let attackClient = ShortCodePakeParticipant(role: .client, config: config)
        do {
            let serverKeys = try attackServer.computeConfirmationKeys(
                peerEphemeralKey: attackClient.ephemeralPublicKey,
                peerNonce: attackClient.localNonce,
                enteredCode: correctCode
            )
            let wrongClientKeys = try attackClient.computeConfirmationKeys(
                peerEphemeralKey: attackServer.ephemeralPublicKey,
                peerNonce: attackServer.localNonce,
                enteredCode: wrongCode
            )
            let sTranscript = attackServer.buildTranscript(
                remoteEphemeralKey: attackClient.ephemeralPublicKey,
                remoteNonce: attackClient.localNonce
            )
            let wrongTag = attackClient.generateConfirmationTag(keys: wrongClientKeys, transcript: sTranscript)

            // Attempt 1 to 4 should increment failed count without locking out yet
            for i in 1...4 {
                let res = attackServer.verifyConfirmationTag(peerTag: wrongTag, expectedKey: serverKeys.clientKey, transcript: sTranscript)
                if case .failure(let err) = res, err == .tagMismatch(attemptsRemaining: 5 - i) {
                    assertCondition(true, "Attempt \(i) failed with \(5 - i) remaining")
                } else {
                    assertCondition(false, "Attempt \(i) unexpected result: \(res)")
                }
                assertCondition(!attackServer.isLockedOut, "Server not yet locked out on attempt \(i)")
            }

            // Attempt 5 should lock out
            let res5 = attackServer.verifyConfirmationTag(peerTag: wrongTag, expectedKey: serverKeys.clientKey, transcript: sTranscript)
            if case .failure(let err) = res5, err == .tagMismatch(attemptsRemaining: 0) {
                assertCondition(true, "Attempt 5 exhausted remaining attempts")
            } else {
                assertCondition(false, "Attempt 5 unexpected result: \(res5)")
            }
            assertCondition(attackServer.isLockedOut, "Server is now locked out after 5 failures")

            // Further attempt rejected immediately with maxAttemptsExceeded
            let res6 = attackServer.verifyConfirmationTag(peerTag: wrongTag, expectedKey: serverKeys.clientKey, transcript: sTranscript)
            if case .failure(let err) = res6, err == .maxAttemptsExceeded {
                assertCondition(true, "Subsequent attempts blocked by lockout")
            } else {
                assertCondition(false, "Subsequent attempt unexpected result: \(res6)")
            }
        } catch {
            assertCondition(false, "PAKE lockout test threw: \(error)")
        }
    }

    static func testDiscoveryServiceBasics() {
        print("\n--- Testing DiscoveryService Basics ---")
        let discovery = DiscoveryService()
        discovery.startAdvertising(
            identity: "ns1_test_mac_discovery_id",
            deviceName: "Test Mac",
            port: 41499,
            isReceiving: true
        )
        discovery.updateReceivingStatus(false)
        discovery.stop()
        assertCondition(true, "DiscoveryService start, update, and stop completed cleanly")
    }
}
