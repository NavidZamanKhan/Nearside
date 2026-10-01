import Foundation
import CryptoKit

@main
struct TestHarnessE3 {
    static func main() async {
        print("==================================================")
        print("  Nearside E3 Feasibility Probe: Cryptography Tests")
        print("==================================================")

        var passedCount = 0
        var failedCount = 0

        func runTest(name: String, block: () throws -> Void) {
            print("\n[TEST] Running: \(name)")
            do {
                try block()
                print("  -> PASSED: \(name)")
                passedCount += 1
            } catch {
                print("  -> FAILED: \(name) with error: \(error)")
                failedCount += 1
            }
        }

        // Test 1: Device Identity and Canonical SPKI Fingerprint
        runTest(name: "P-256 Identity and Canonical SPKI Fingerprint") {
            let identity = DeviceIdentity()
            guard identity.publicIdentity.hasPrefix("ns1_") else {
                throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Identity must start with ns1_"])
            }
            guard identity.publicIdentity.count == 4 + 64 else { // "ns1_" + 64 hex chars
                throw NSError(domain: "Test", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid identity length: \(identity.publicIdentity.count)"])
            }

            // Test signing and verification
            let samplePayload = "NEAR_SIDE_AUTHENTICATED_FRAME_PAYLOAD".data(using: .utf8)!
            let signature = try identity.sign(data: samplePayload)
            let isValid = DeviceIdentity.verify(signature: signature, for: samplePayload, publicKey: identity.publicKey)
            guard isValid else {
                throw NSError(domain: "Test", code: 3, userInfo: [NSLocalizedDescriptionKey: "Signature verification failed"])
            }

            // Negative: Corrupted payload verification fails
            let corruptedPayload = "CORRUPTED_FRAME_PAYLOAD".data(using: .utf8)!
            let isCorruptValid = DeviceIdentity.verify(signature: signature, for: corruptedPayload, publicKey: identity.publicKey)
            guard !isCorruptValid else {
                throw NSError(domain: "Test", code: 4, userInfo: [NSLocalizedDescriptionKey: "Corrupted signature should fail"])
            }
            print("  [EVIDENCE] Generated identity: \(identity.publicIdentity) with verified ECDSA P-256 signatures.")
        }

        // Test 2: Pinned Trust Store and Authorization Policies
        runTest(name: "Pinned Trust Store and Policy Evaluation") {
            var trustStore = PinnedTrustStore()
            let peerA = DeviceIdentity()
            let peerB = DeviceIdentity()

            // 1. Unenrolled peer is rejected
            let unverifiedResult = trustStore.validatePeer(presentedSpki: peerA.spkiDer)
            guard case .failure(.untrustedPeer(let id)) = unverifiedResult, id == peerA.publicIdentity else {
                throw NSError(domain: "Test", code: 5, userInfo: [NSLocalizedDescriptionKey: "Unenrolled peer should be untrusted"])
            }

            // 2. Enroll peerA
            trustStore.enroll(identity: peerA.publicIdentity, publicKey: peerA.publicKey)
            let verifiedResult = trustStore.validatePeer(presentedSpki: peerA.spkiDer)
            guard case .success(let verifiedId) = verifiedResult, verifiedId == peerA.publicIdentity else {
                throw NSError(domain: "Test", code: 6, userInfo: [NSLocalizedDescriptionKey: "Enrolled peer should be verified"])
            }

            // 3. Block peerA
            trustStore.block(identity: peerA.publicIdentity)
            let blockedResult = trustStore.validatePeer(presentedSpki: peerA.spkiDer)
            guard case .failure(.peerBlocked(let blockedId)) = blockedResult, blockedId == peerA.publicIdentity else {
                throw NSError(domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "Blocked peer should be rejected"])
            }

            // 4. Unpair peerA
            trustStore.unpair(identity: peerA.publicIdentity)
            let unpairedResult = trustStore.validatePeer(presentedSpki: peerA.spkiDer)
            guard case .failure(.untrustedPeer) = unpairedResult else {
                throw NSError(domain: "Test", code: 8, userInfo: [NSLocalizedDescriptionKey: "Unpaired peer should return to untrusted"])
            }

            // 5. PeerB remains untrusted
            let peerBResult = trustStore.validatePeer(presentedSpki: peerB.spkiDer)
            guard case .failure(.untrustedPeer) = peerBResult else {
                throw NSError(domain: "Test", code: 9, userInfo: [NSLocalizedDescriptionKey: "Peer B should be untrusted"])
            }
        }

        // Test 3: QR-Based Pairing Protocol (Happy Path)
        runTest(name: "QR Pairing: Transcript Binding and Confirmation") {
            let hostIdentity = DeviceIdentity()
            let clientIdentity = DeviceIdentity()

            let payload = QRPairingPayload(hostIdentity: hostIdentity.publicIdentity)
            let hostSession = QRPairingSession(role: .host, localIdentity: hostIdentity, payload: payload)
            let clientSession = QRPairingSession(role: .client, localIdentity: clientIdentity, payload: payload)

            // Transcript constructed with both nonces and role-ordered identities
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
            guard hostTranscript == clientTranscript else {
                throw NSError(domain: "Test", code: 10, userInfo: [NSLocalizedDescriptionKey: "Transcripts do not match"])
            }

            // Both derive confirmation keys from QR secret
            let hostKeys = try hostSession.deriveConfirmationKeys(transcript: hostTranscript)
            let clientKeys = try clientSession.deriveConfirmationKeys(transcript: clientTranscript)

            // Client computes tag, Host verifies
            let clientTag = clientSession.generateConfirmation(keys: clientKeys, transcript: clientTranscript)
            let hostVerifiedClient = hostSession.verifyPeerConfirmation(
                peerMac: clientTag,
                expectedKey: hostKeys.clientKey,
                transcript: hostTranscript
            )
            guard hostVerifiedClient else {
                throw NSError(domain: "Test", code: 11, userInfo: [NSLocalizedDescriptionKey: "Host failed to verify client tag"])
            }

            // Host computes tag, Client verifies
            let hostTag = hostSession.generateConfirmation(keys: hostKeys, transcript: hostTranscript)
            let clientVerifiedHost = clientSession.verifyPeerConfirmation(
                peerMac: hostTag,
                expectedKey: clientKeys.serverKey,
                transcript: clientTranscript
            )
            guard clientVerifiedHost else {
                throw NSError(domain: "Test", code: 12, userInfo: [NSLocalizedDescriptionKey: "Client failed to verify host tag"])
            }
            print("  [EVIDENCE] Mutual QR confirmation passed with constant-time HMAC-SHA256 validation.")
        }

        // Test 4: QR Pairing Negative Cases (Expired QR, Wrong Secret)
        runTest(name: "QR Pairing Negative Cases: Expiry and Secret Tampering") {
            let hostIdentity = DeviceIdentity()
            let clientIdentity = DeviceIdentity()

            // Negative A: Expired QR payload
            let expiredPayload = QRPairingPayload(hostIdentity: hostIdentity.publicIdentity, expirySeconds: -1.0)
            let clientSession = QRPairingSession(role: .client, localIdentity: clientIdentity, payload: expiredPayload)
            do {
                _ = try clientSession.deriveConfirmationKeys(transcript: Data("dummy".utf8))
                throw NSError(domain: "Test", code: 13, userInfo: [NSLocalizedDescriptionKey: "Expired QR should throw"])
            } catch let error as PairingError {
                guard error == .sessionExpired else {
                    throw NSError(domain: "Test", code: 14, userInfo: [NSLocalizedDescriptionKey: "Expected sessionExpired, got \(error)"])
                }
            }

            // Negative B: Wrong QR Secret
            let validPayload = QRPairingPayload(hostIdentity: hostIdentity.publicIdentity)
            let hostSession = QRPairingSession(role: .host, localIdentity: hostIdentity, payload: validPayload)
            let transcript = hostSession.buildTranscript(
                remoteNonce: Data(repeating: 1, count: 32),
                clientIdentity: clientIdentity.publicIdentity,
                serverIdentity: hostIdentity.publicIdentity
            )
            let hostKeys = try hostSession.deriveConfirmationKeys(transcript: transcript)

            let forgedKey = SymmetricKey(size: .bits256)
            let forgedTag = Data(HMAC<SHA256>.authenticationCode(for: transcript, using: forgedKey))
            let verified = hostSession.verifyPeerConfirmation(
                peerMac: forgedTag,
                expectedKey: hostKeys.clientKey,
                transcript: transcript
            )
            guard !verified else {
                throw NSError(domain: "Test", code: 15, userInfo: [NSLocalizedDescriptionKey: "Forged tag must be rejected"])
            }
        }

        // Test 5: Short-Code PAKE Protocol (Happy Path)
        runTest(name: "Short-Code PAKE: 8-Digit Secret Agreement") {
            let serverIdentity = DeviceIdentity()
            let clientIdentity = DeviceIdentity()
            let enteredCode = "48291054"

            let config = PakeSessionConfig(
                shortCode: enteredCode,
                serverIdentity: serverIdentity.publicIdentity,
                clientIdentity: clientIdentity.publicIdentity
            )

            let server = ShortCodePakeParticipant(role: .server, config: config)
            let client = ShortCodePakeParticipant(role: .client, config: config)

            // Both compute confirmation keys
            let serverKeys = try server.computeConfirmationKeys(
                peerEphemeralKey: client.ephemeralPublicKey,
                peerNonce: client.localNonce,
                enteredCode: enteredCode
            )
            let clientKeys = try client.computeConfirmationKeys(
                peerEphemeralKey: server.ephemeralPublicKey,
                peerNonce: server.localNonce,
                enteredCode: enteredCode
            )

            let transcript = server.buildTranscript(
                remoteEphemeralKey: client.ephemeralPublicKey,
                remoteNonce: client.localNonce
            )

            // Client sends tag, Server verifies
            let clientTag = client.generateConfirmationTag(keys: clientKeys, transcript: transcript)
            let serverResult = server.verifyConfirmationTag(
                peerTag: clientTag,
                expectedKey: serverKeys.clientKey,
                transcript: transcript
            )
            guard case .success = serverResult else {
                throw NSError(domain: "Test", code: 16, userInfo: [NSLocalizedDescriptionKey: "Server failed to verify client PAKE tag"])
            }

            // Server sends tag, Client verifies
            let serverTag = server.generateConfirmationTag(keys: serverKeys, transcript: transcript)
            let clientResult = client.verifyConfirmationTag(
                peerTag: serverTag,
                expectedKey: clientKeys.serverKey,
                transcript: transcript
            )
            guard case .success = clientResult else {
                throw NSError(domain: "Test", code: 17, userInfo: [NSLocalizedDescriptionKey: "Client failed to verify server PAKE tag"])
            }
            print("  [EVIDENCE] Short-code PAKE key agreement and confirmation passed with matching 8-digit code.")
        }

        // Test 6: Short-Code PAKE Wrong Code and Rate-Limiting Lockout
        runTest(name: "Short-Code PAKE: 5-Attempt Rate Limiting Lockout") {
            let serverIdentity = DeviceIdentity()
            let clientIdentity = DeviceIdentity()
            let realCode = "88992211"

            let config = PakeSessionConfig(
                shortCode: realCode,
                serverIdentity: serverIdentity.publicIdentity,
                clientIdentity: clientIdentity.publicIdentity,
                maxAttempts: 5
            )

            let server = ShortCodePakeParticipant(role: .server, config: config)
            let client = ShortCodePakeParticipant(role: .client, config: config)

            let transcript = server.buildTranscript(
                remoteEphemeralKey: client.ephemeralPublicKey,
                remoteNonce: client.localNonce
            )
            let serverKeys = try server.computeConfirmationKeys(
                peerEphemeralKey: client.ephemeralPublicKey,
                peerNonce: client.localNonce,
                enteredCode: realCode
            )

            // Attacker enters 5 wrong guesses
            let attackerWrongKey = SymmetricKey(size: .bits256)
            let forgedTag = Data(HMAC<SHA256>.authenticationCode(for: transcript, using: attackerWrongKey))

            for attempt in 1...5 {
                let result = server.verifyConfirmationTag(
                    peerTag: forgedTag,
                    expectedKey: serverKeys.clientKey,
                    transcript: transcript
                )
                guard case .failure(.tagMismatch(let remaining)) = result else {
                    throw NSError(domain: "Test", code: 18, userInfo: [NSLocalizedDescriptionKey: "Attempt \(attempt) should have failed with tagMismatch"])
                }
                guard remaining == (5 - attempt) else {
                    throw NSError(domain: "Test", code: 19, userInfo: [NSLocalizedDescriptionKey: "Expected \(5 - attempt) remaining, got \(remaining)"])
                }
            }

            guard server.isLockedOut else {
                throw NSError(domain: "Test", code: 20, userInfo: [NSLocalizedDescriptionKey: "Server must be locked out after 5 failures"])
            }

            // 6th attempt is blocked by rate-limiter before checking tag
            let sixthAttempt = server.verifyConfirmationTag(
                peerTag: forgedTag,
                expectedKey: serverKeys.clientKey,
                transcript: transcript
            )
            guard case .failure(.maxAttemptsExceeded) = sixthAttempt else {
                throw NSError(domain: "Test", code: 21, userInfo: [NSLocalizedDescriptionKey: "6th attempt must be rejected with maxAttemptsExceeded"])
            }
            print("  [EVIDENCE] Confirmed: 5 failed attempts permanently lock out the PAKE session.")
        }

        // Test 7: PAKE MITM Transcript Tampering Detection
        runTest(name: "Short-Code PAKE: MITM Transcript Tampering Detection") {
            let serverIdentity = DeviceIdentity()
            let clientIdentity = DeviceIdentity()
            let code = "12345678"

            let config = PakeSessionConfig(
                shortCode: code,
                serverIdentity: serverIdentity.publicIdentity,
                clientIdentity: clientIdentity.publicIdentity
            )

            let server = ShortCodePakeParticipant(role: .server, config: config)
            let client = ShortCodePakeParticipant(role: .client, config: config)

            let honestTranscript = server.buildTranscript(
                remoteEphemeralKey: client.ephemeralPublicKey,
                remoteNonce: client.localNonce
            )
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

            // Attacker modifies transcript (e.g. substitutes a single byte)
            var tamperedTranscript = honestTranscript
            tamperedTranscript[tamperedTranscript.count - 1] ^= 0xFF

            let clientTamperedTag = client.generateConfirmationTag(keys: clientKeys, transcript: tamperedTranscript)
            let result = server.verifyConfirmationTag(
                peerTag: clientTamperedTag,
                expectedKey: serverKeys.clientKey,
                transcript: honestTranscript
            )

            guard case .failure(.tagMismatch) = result else {
                throw NSError(domain: "Test", code: 22, userInfo: [NSLocalizedDescriptionKey: "Tampered transcript must be rejected"])
            }
            print("  [EVIDENCE] Confirmed: Any transcript alteration causes immediate tag verification failure.")
        }

        print("\n==================================================")
        print("  Summary: \(passedCount) Passed, \(failedCount) Failed")
        print("==================================================")
        if failedCount > 0 {
            exit(1)
        }
    }
}
