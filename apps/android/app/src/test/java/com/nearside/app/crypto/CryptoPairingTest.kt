package com.nearside.app.crypto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class CryptoPairingTest {

    @Test
    fun testDeviceIdentityGenerationAndSignVerify() {
        val identity = DeviceIdentity.generateEphemeral()
        assertTrue(identity.publicIdentity.startsWith("ns1_"))
        assertEquals(68, identity.publicIdentity.length)
        assertTrue(identity.spkiDer.isNotEmpty())

        val message = "TestNearsideAndroidData".toByteArray(Charsets.UTF_8)
        val signature = identity.sign(message)
        assertTrue(signature.isNotEmpty())

        val valid = DeviceIdentity.verify(signature, message, identity.publicKey)
        assertTrue(valid)

        val tampered = "TamperedNearsideData".toByteArray(Charsets.UTF_8)
        val invalid = DeviceIdentity.verify(signature, tampered, identity.publicKey)
        assertFalse(invalid)
    }

    @Test
    fun testPinnedTrustStoreLifecycle() {
        val tempFile = Files.createTempFile("nearside_trust", ".json").toFile()
        tempFile.deleteOnExit()

        val store = PinnedTrustStore(tempFile)
        val peerIdentity = DeviceIdentity.generateEphemeral()
        val peerId = peerIdentity.publicIdentity
        val peerSpki = peerIdentity.spkiDer

        // 1. Unknown initially
        val initialRes = store.validatePeer(peerSpki)
        assertTrue(initialRes is TrustResult.UntrustedPeer)

        // 2. Enroll
        store.enroll(peerId, "MacBook Pro", "macos", peerIdentity.publicKey)
        assertTrue(store.isEnrolled(peerId))
        val enrolledRes = store.validatePeer(peerSpki)
        assertTrue(enrolledRes is TrustResult.Success)
        assertEquals(peerId, (enrolledRes as TrustResult.Success).identity)

        // 3. Block
        store.block(peerId)
        val blockedRes = store.validatePeer(peerSpki)
        assertTrue(blockedRes is TrustResult.PeerBlocked)

        // 4. Unpair
        store.unpair(peerId)
        assertFalse(store.isEnrolled(peerId))
        val unpairRes = store.validatePeer(peerSpki)
        assertTrue(unpairRes is TrustResult.UntrustedPeer)
    }

    @Test
    fun testQRPairingProtocolHandshake() {
        val host = DeviceIdentity.generateEphemeral()
        val client = DeviceIdentity.generateEphemeral()

        val payload = QRPairingPayload.createNew(host.publicIdentity, "MacBook Pro")
        assertFalse(payload.isExpired)

        val uri = payload.toUri()
        assertTrue(uri.startsWith("nearside://pair?"))

        val parsed = QRPairingPayload.fromUri(uri)
        assertNotNull(parsed)
        assertEquals(payload.sessionId, parsed!!.sessionId)
        assertEquals(payload.hostIdentity, parsed.hostIdentity)
        assertEquals(payload.sharedSecretBase64, parsed.sharedSecretBase64)

        val hostSession = QRPairingSession(QRPairingSession.Role.HOST, host, payload)
        val clientSession = QRPairingSession(QRPairingSession.Role.CLIENT, client, parsed)

        val hostTranscript = hostSession.buildTranscript(
            remoteNonce = clientSession.localNonce,
            clientIdentity = client.publicIdentity,
            serverIdentity = host.publicIdentity
        )

        val clientTranscript = clientSession.buildTranscript(
            remoteNonce = hostSession.localNonce,
            clientIdentity = client.publicIdentity,
            serverIdentity = host.publicIdentity
        )

        assertTrue(hostTranscript.contentEquals(clientTranscript))

        val hostKeys = hostSession.deriveConfirmationKeys(hostTranscript)
        val clientKeys = clientSession.deriveConfirmationKeys(clientTranscript)

        val hostConfirm = hostSession.generateConfirmation(hostKeys, hostTranscript)
        val clientConfirm = clientSession.generateConfirmation(clientKeys, clientTranscript)

        val clientVerifiedHost = clientSession.verifyPeerConfirmation(
            peerMac = hostConfirm,
            expectedKey = clientKeys.second,
            transcript = clientTranscript
        )
        assertTrue(clientVerifiedHost)

        val hostVerifiedClient = hostSession.verifyPeerConfirmation(
            peerMac = clientConfirm,
            expectedKey = hostKeys.first,
            transcript = hostTranscript
        )
        assertTrue(hostVerifiedClient)

        // Tampered confirmation MAC
        val tamperedMac = clientConfirm.clone()
        tamperedMac[0] = (tamperedMac[0].toInt() xor 0xFF).toByte()
        val rejectedTampered = hostSession.verifyPeerConfirmation(
            peerMac = tamperedMac,
            expectedKey = hostKeys.first,
            transcript = hostTranscript
        )
        assertFalse(rejectedTampered)
    }

    @Test
    fun testShortCodePakeHandshakeAndLockout() {
        val correctCode = "48192034"
        val wrongCode = "99999999"
        val serverId = "ns1_server_identity_hash_here_11223344"
        val clientId = "ns1_client_identity_hash_here_55667788"

        val config = PakeSessionConfig(
            shortCode = correctCode,
            serverIdentity = serverId,
            clientIdentity = clientId,
            maxAttempts = 5
        )

        val server = ShortCodePakeParticipant(ShortCodePakeParticipant.Role.SERVER, config)
        val client = ShortCodePakeParticipant(ShortCodePakeParticipant.Role.CLIENT, config)

        val serverKeys = server.computeConfirmationKeys(
            peerEphemeralKey = client.ephemeralKeyPair.public,
            peerNonce = client.localNonce,
            enteredCode = correctCode
        )

        val clientKeys = client.computeConfirmationKeys(
            peerEphemeralKey = server.ephemeralKeyPair.public,
            peerNonce = server.localNonce,
            enteredCode = correctCode
        )

        val serverTranscript = server.buildTranscript(
            remoteEphemeralKey = client.ephemeralKeyPair.public,
            remoteNonce = client.localNonce
        )
        val clientTranscript = client.buildTranscript(
            remoteEphemeralKey = server.ephemeralKeyPair.public,
            remoteNonce = server.localNonce
        )
        assertTrue(serverTranscript.contentEquals(clientTranscript))

        val serverTag = server.generateConfirmationTag(serverKeys, serverTranscript)
        val clientTag = client.generateConfirmationTag(clientKeys, clientTranscript)

        val clientVerify = client.verifyConfirmationTag(serverTag, clientKeys.second, clientTranscript)
        assertTrue(clientVerify is PakeResult.Success)

        val serverVerify = server.verifyConfirmationTag(clientTag, serverKeys.first, serverTranscript)
        assertTrue(serverVerify is PakeResult.Success)

        // Lockout test with wrong code
        val attackServer = ShortCodePakeParticipant(ShortCodePakeParticipant.Role.SERVER, config)
        val attackClient = ShortCodePakeParticipant(ShortCodePakeParticipant.Role.CLIENT, config)

        val aServerKeys = attackServer.computeConfirmationKeys(
            peerEphemeralKey = attackClient.ephemeralKeyPair.public,
            peerNonce = attackClient.localNonce,
            enteredCode = correctCode
        )
        val wrongClientKeys = attackClient.computeConfirmationKeys(
            peerEphemeralKey = attackServer.ephemeralKeyPair.public,
            peerNonce = attackServer.localNonce,
            enteredCode = wrongCode
        )
        val sTranscript = attackServer.buildTranscript(
            remoteEphemeralKey = attackClient.ephemeralKeyPair.public,
            remoteNonce = attackClient.localNonce
        )
        val wrongTag = attackClient.generateConfirmationTag(wrongClientKeys, sTranscript)

        for (i in 1..4) {
            val res = attackServer.verifyConfirmationTag(wrongTag, aServerKeys.first, sTranscript)
            assertTrue(res is PakeResult.TagMismatch)
            assertEquals(5 - i, (res as PakeResult.TagMismatch).attemptsRemaining)
            assertFalse(attackServer.isLockedOut)
        }

        val res5 = attackServer.verifyConfirmationTag(wrongTag, aServerKeys.first, sTranscript)
        assertTrue(res5 is PakeResult.TagMismatch)
        assertEquals(0, (res5 as PakeResult.TagMismatch).attemptsRemaining)
        assertTrue(attackServer.isLockedOut)

        val res6 = attackServer.verifyConfirmationTag(wrongTag, aServerKeys.first, sTranscript)
        assertTrue(res6 is PakeResult.MaxAttemptsExceeded)
    }

    @Test
    fun testHkdfRfc5869() {
        val ikm = "InputKeyMaterial".toByteArray(Charsets.UTF_8)
        val salt = "SaltStringHere".toByteArray(Charsets.UTF_8)
        val info = "ApplicationInfo".toByteArray(Charsets.UTF_8)

        val key1 = Hkdf.deriveKey(ikm, salt, info, 32)
        val key2 = Hkdf.deriveKey(ikm, salt, info, 32)

        assertEquals(32, key1.size)
        assertTrue(key1.contentEquals(key2))

        val keyDiffInfo = Hkdf.deriveKey(ikm, salt, "OtherInfo".toByteArray(Charsets.UTF_8), 32)
        assertFalse(key1.contentEquals(keyDiffInfo))
    }
}
