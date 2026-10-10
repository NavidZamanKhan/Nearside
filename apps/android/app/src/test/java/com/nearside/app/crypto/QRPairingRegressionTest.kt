package com.nearside.app.crypto

import com.nearside.app.diagnostics.NearsideError
import com.nearside.app.diagnostics.NearsideErrorCode
import com.nearside.app.transfer.*
import org.junit.Assert.*
import org.junit.Test
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileNotFoundException
import java.net.ServerSocket
import java.net.Socket
import java.nio.file.Files
import java.util.Base64
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class QRPairingRegressionTest {
    private fun payload() = QRPairingPayload.createNew(DeviceIdentity.generateEphemeral().publicIdentity, "Mac + Phone / Café", "192.168.1.10")

    @Test fun crossPlatformConfirmationVectorMatchesSwiftAndRfcHkdf() {
        val hostId = "ns1_" + "2".repeat(64); val clientId = "ns1_" + "1".repeat(64)
        val payload = payload().copy(sessionId = "11111111-1111-4111-8111-111111111111", hostIdentity = hostId,
            sharedSecretBase64 = "QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8=")
        val host = QRPairingSession(QRPairingSession.Role.HOST, DeviceIdentity.generateEphemeral(), payload)
        for (i in 0 until 32) host.localNonce[i] = (i + 32).toByte()
        val transcript = host.buildTranscript(ByteArray(32) { it.toByte() }, clientId, hostId)
        val keys = host.deriveConfirmationKeys(transcript)
        assertEquals("8AiTClp/ehVR8JWEkRNu1Ix2uBSZ3bjNOKQTjnrFNGg=", Base64.getEncoder().encodeToString(host.generateConfirmation(keys, transcript)))
        assertEquals("VrlzH+wqEKnqMAcEmfyF4UEg+B29XBI/qV7/PKZKkMs=", Base64.getEncoder().encodeToString(host.generateConfirmation(keys, transcript + "nearside-qr-accepted".toByteArray())))
    }

    @Test fun uriPreservesOriginalExpiryAndEncodedValues() {
        val payload = payload().copy(sharedSecretBase64 = Base64.getEncoder().encodeToString(ByteArray(32) { 0xfb.toByte() }))
        val parsed = QRPairingPayload.fromUri(payload.toUri())!!
        assertEquals(payload, parsed)
        assertTrue(parsed.sharedSecretBase64.contains("+"))
        assertEquals(payload.hostName, parsed.hostName)
    }

    @Test fun expiredCodeDoesNotGainFreshLifetimeOnScan() {
        val old = payload().copy(createdAtSeconds = System.currentTimeMillis() / 1000.0 - 181)
        assertTrue(QRPairingPayload.fromUri(old.toUri())!!.isExpired)
        assertFalse(old.isValidAt(old.createdAtSeconds + 180))
    }

    @Test fun malformedMissingDuplicateAndUnsupportedFieldsAreRejected() {
        val uri = payload().toUri()
        listOf(uri.replace("v=1", "v=2"), uri.replace("v=1&", ""), uri + "&sid=duplicate",
            uri.replace(Regex("sec=[^&]+"), "sec=YWJj"), uri.replace(Regex("id=[^&]+"), "id=ns1_dummy"),
            uri.replace("port=41433", "port=65536"), uri.replace(Regex("created=[^&]+"), "created=NaN"),
            uri.replace(Regex("ttl=[^&]+"), "ttl=Infinity"), uri.replace(Regex("ttl=[^&]+"), "ttl=181"),
            uri.replace("nearside://pair", "https://pair"), uri + "#fragment").forEach { assertNull(it, QRPairingPayload.fromUri(it)) }
    }

    @Test fun futureDatedPayloadIsInvalid() {
        assertTrue(payload().copy(createdAtSeconds = System.currentTimeMillis() / 1000.0 + 60).isExpired)
    }

    @Test fun activeSessionsConsumeOnceAndDisappearAfterDismissal() {
        val p = payload()
        QRPairingSessions.register(p)
        assertEquals(p, QRPairingSessions.requireActive(p.sessionId))
        assertTrue(QRPairingSessions.consume(p.sessionId))
        assertFalse(QRPairingSessions.consume(p.sessionId))
        expectCode(NearsideErrorCode.PAIRING_SESSION_EXPIRED) { QRPairingSessions.requireActive(p.sessionId) }
        QRPairingSessions.register(p); QRPairingSessions.unregister(p.sessionId)
        expectCode(NearsideErrorCode.PAIRING_SESSION_EXPIRED) { QRPairingSessions.requireActive(p.sessionId) }
    }

    @Test fun expiredHostSessionsCannotAuthorizeEnrollment() {
        val p = payload().copy(createdAtSeconds = 1.0)
        QRPairingSessions.register(p)
        expectCode(NearsideErrorCode.PAIRING_SESSION_EXPIRED) { QRPairingSessions.requireActive(p.sessionId) }
        assertFalse(QRPairingSessions.consume(p.sessionId))
    }

    @Test fun wrongSecretAndIdentityCannotProduceAcceptedProof() {
        val host = DeviceIdentity.generateEphemeral(); val client = DeviceIdentity.generateEphemeral()
        val p = QRPairingPayload.createNew(host.publicIdentity, "Mac")
        val serverSession = QRPairingSession(QRPairingSession.Role.HOST, host, p)
        val clientSession = QRPairingSession(QRPairingSession.Role.CLIENT, client, p.copy(sharedSecretBase64 = Base64.getEncoder().encodeToString(ByteArray(32))))
        val server = QRPairingHandshake(serverSession, client.publicIdentity, host.publicIdentity)
        val clientHandshake = QRPairingHandshake(clientSession, client.publicIdentity, host.publicIdentity)
        val proof = clientHandshake.confirmation(Base64.getEncoder().encodeToString(serverSession.localNonce))
        expectCode(NearsideErrorCode.PAIRING_VERIFICATION_FAILED) { server.verify(Base64.getEncoder().encodeToString(clientSession.localNonce), proof) }
        expectCode(NearsideErrorCode.PAIRING_VERIFICATION_FAILED) {
            QRPairingHandshake(clientSession, client.publicIdentity, client.publicIdentity).confirmation(Base64.getEncoder().encodeToString(serverSession.localNonce))
        }
    }

    @Test fun malformedNonceAndTamperedConfirmationAreRejected() {
        val host = DeviceIdentity.generateEphemeral(); val client = DeviceIdentity.generateEphemeral()
        val p = QRPairingPayload.createNew(host.publicIdentity, "Mac")
        val session = QRPairingSession(QRPairingSession.Role.CLIENT, client, p)
        val handshake = QRPairingHandshake(session, client.publicIdentity, host.publicIdentity)
        expectCode(NearsideErrorCode.PAIRING_VERIFICATION_FAILED) { handshake.confirmation("YWJj") }
        expectCode(NearsideErrorCode.PAIRING_VERIFICATION_FAILED) { handshake.verify(Base64.getEncoder().encodeToString(ByteArray(32)), "!") }
    }

    @Test fun challengeProofCannotBeReusedAsFinalAcceptance() {
        val host = DeviceIdentity.generateEphemeral(); val client = DeviceIdentity.generateEphemeral()
        val p = QRPairingPayload.createNew(host.publicIdentity, "Mac")
        val hs = QRPairingSession(QRPairingSession.Role.HOST, host, p)
        val cs = QRPairingSession(QRPairingSession.Role.CLIENT, client, p)
        val server = QRPairingHandshake(hs, client.publicIdentity, host.publicIdentity)
        val verifier = QRPairingHandshake(cs, client.publicIdentity, host.publicIdentity)
        val cn = Base64.getEncoder().encodeToString(cs.localNonce)
        val hn = Base64.getEncoder().encodeToString(hs.localNonce)
        expectCode(NearsideErrorCode.PAIRING_VERIFICATION_FAILED) { verifier.verify(hn, server.confirmation(cn), accepted = true) }
        verifier.verify(hn, server.confirmation(cn, accepted = true), accepted = true)
    }

    @Test fun peerPublicKeyMustMatchScannedIdentityAndMustNotBeBlocked() {
        val peer = DeviceIdentity.generateEphemeral(); val other = DeviceIdentity.generateEphemeral(); val store = PinnedTrustStore()
        val spki = Base64.getEncoder().encodeToString(peer.spkiDer)
        expectCode(NearsideErrorCode.TRUST_KEY_MISMATCH) { QRPairingHandshake.validatePeer(other.publicIdentity, spki, store) }
        store.block(peer.publicIdentity)
        expectCode(NearsideErrorCode.TRUST_PEER_BLOCKED) { QRPairingHandshake.validatePeer(peer.publicIdentity, spki, store) }
        assertFalse(store.isEnrolled(peer.publicIdentity))
    }

    @Test fun oversizedPairFrameRejectedBeforeAllocation() {
        val buffer = ByteArrayOutputStream(); DataOutputStream(buffer).writeInt(Int.MAX_VALUE)
        expectCode(NearsideErrorCode.PAIRING_MALFORMED_PAYLOAD) { QRPairingTransport.readPayload(DataInputStream(ByteArrayInputStream(buffer.toByteArray()))) }
    }

    @Test fun qrTransportMutuallyEnrollsAndRejectsSessionReplay() {
        val host = DeviceIdentity.generateEphemeral(); val client = DeviceIdentity.generateEphemeral()
        val p = QRPairingPayload.createNew(host.publicIdentity, "Mac")
        val hostTrust = PinnedTrustStore(); val clientTrust = PinnedTrustStore()
        QRPairingSessions.register(p)
        ServerSocket(0).use { server ->
            val pool = Executors.newSingleThreadExecutor()
            try {
                val serving = pool.submit<PairResponseFrame> {
                    server.accept().use { socket ->
                        socket.soTimeout = 3000
                        val input = DataInputStream(socket.getInputStream()); val output = DataOutputStream(socket.getOutputStream())
                        val first = PairRequestFrame.fromJson(QRPairingTransport.read(input, FrameType.PAIR_REQUEST))
                        assertFalse(hostTrust.isEnrolled(client.publicIdentity))
                        QRPairingTransport.server(input, output, first, host, "Mac", hostTrust)
                    }
                }
                Socket("127.0.0.1", server.localPort).use { socket ->
                    socket.soTimeout = 3000
                    val response = QRPairingTransport.client(DataInputStream(socket.getInputStream()), DataOutputStream(socket.getOutputStream()),
                        client, "Phone", p, clientTrust, "127.0.0.1", server.localPort)
                    assertEquals(host.publicIdentity, response.serverId)
                }
                assertEquals("ACCEPTED", serving.get(5, TimeUnit.SECONDS).status)
                assertTrue(hostTrust.isEnrolled(client.publicIdentity)); assertTrue(clientTrust.isEnrolled(host.publicIdentity))
                expectCode(NearsideErrorCode.PAIRING_SESSION_EXPIRED) { QRPairingSessions.requireActive(p.sessionId) }
            } finally { pool.shutdownNow(); QRPairingSessions.unregister(p.sessionId) }
        }
    }

    @Test fun unregisteredSessionCannotEnrollPeer() {
        val host = DeviceIdentity.generateEphemeral(); val client = DeviceIdentity.generateEphemeral(); val trust = PinnedTrustStore()
        val request = PairRequestFrame(client.publicIdentity, "Phone", "android", Base64.getEncoder().encodeToString(client.spkiDer), "",
            qrSessionId = java.util.UUID.randomUUID().toString(), qrNonceBase64 = Base64.getEncoder().encodeToString(ByteArray(32)))
        expectCode(NearsideErrorCode.PAIRING_SESSION_EXPIRED) {
            QRPairingTransport.server(DataInputStream(ByteArrayInputStream(byteArrayOf())), DataOutputStream(ByteArrayOutputStream()), request, host, "Mac", trust)
        }
        assertFalse(trust.isEnrolled(client.publicIdentity))
    }

    @Test fun clientPersistenceFailureKeepsSessionAndNativeCauseWithoutFalseSuccess() {
        verifyPersistenceFailure(clientSide = true)
    }

    @Test fun hostPersistenceFailureKeepsSessionAndCannotSendFinalAcceptance() {
        verifyPersistenceFailure(clientSide = false)
    }

    private fun verifyPersistenceFailure(clientSide: Boolean) {
        val directory = Files.createTempDirectory("nearside-qr-persistence").toFile()
        val host = DeviceIdentity.generateEphemeral()
        val client = DeviceIdentity.generateEphemeral()
        val payload = QRPairingPayload.createNew(host.publicIdentity, "Mac")
        val unavailableParent = File(directory, "unavailable_parent").apply { writeText("fixture") }
        val failingStore = PinnedTrustStore(File(unavailableParent, "trust.json"))
        val hostTrust = if (clientSide) PinnedTrustStore() else failingStore
        val clientTrust = if (clientSide) failingStore else PinnedTrustStore()
        val pool = Executors.newSingleThreadExecutor()
        QRPairingSessions.register(payload)
        try {
            ServerSocket(0).use { server ->
                server.soTimeout = 5000
                val serving = pool.submit<Result<PairResponseFrame>> {
                    runCatching {
                        server.accept().use { socket ->
                            socket.soTimeout = 5000
                            val input = DataInputStream(socket.getInputStream())
                            val output = DataOutputStream(socket.getOutputStream())
                            val first = PairRequestFrame.fromJson(QRPairingTransport.read(input, FrameType.PAIR_REQUEST))
                            QRPairingTransport.server(input, output, first, host, "Mac", hostTrust)
                        }
                    }
                }
                val clientResult = runCatching {
                    Socket("127.0.0.1", server.localPort).use { socket ->
                        socket.soTimeout = 5000
                        QRPairingTransport.client(DataInputStream(socket.getInputStream()), DataOutputStream(socket.getOutputStream()),
                            client, "Phone", payload, clientTrust, "127.0.0.1", server.localPort)
                    }
                }
                val hostResult = serving.get(10, TimeUnit.SECONDS)
                val failedResult = if (clientSide) clientResult else hostResult
                val failure = failedResult.exceptionOrNull() as? NearsideError
                    ?: throw AssertionError("Expected a classified trust persistence failure")
                assertEquals(NearsideErrorCode.TRUST_STORAGE_FAILED, failure.code)
                assertEquals(payload.sessionId, failure.correlationId)
                assertEquals("saveTrustStore", failure.operation)
                assertEquals("trust", failure.subsystem)
                assertEquals("Safe native storage classification must remain available",
                    FileNotFoundException::class.java.name, failure.underlyingError?.message)
                assertFalse(failure.toString().contains(unavailableParent.absolutePath))
                assertFalse(failure.toString().contains(payload.sharedSecretBase64))
                assertFalse(failingStore.isEnrolled(if (clientSide) host.publicIdentity else client.publicIdentity))
                assertFalse(clientTrust.isEnrolled(host.publicIdentity))
                if (clientSide) {
                    assertEquals("ACCEPTED", hostResult.getOrThrow().status)
                    assertTrue(hostTrust.isEnrolled(client.publicIdentity))
                } else {
                    assertTrue(clientResult.isFailure)
                    assertFalse(hostTrust.isEnrolled(client.publicIdentity))
                }
            }
        } finally {
            pool.shutdownNow()
            QRPairingSessions.unregister(payload.sessionId)
            directory.deleteRecursively()
        }
    }

    private fun expectCode(code: NearsideErrorCode, action: () -> Unit) {
        try { action(); fail("Expected ${code.code}") } catch (error: NearsideError) { assertEquals(code, error.code) }
    }
}
