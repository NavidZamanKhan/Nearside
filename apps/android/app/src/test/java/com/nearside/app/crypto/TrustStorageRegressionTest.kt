package com.nearside.app.crypto

import com.nearside.app.diagnostics.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.Base64
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class TrustStorageRegressionTest {
    @Test fun uiAndReceiverShareEnrollmentBlocksEndpointsAndNotifications() = withDirectory { root ->
        val file = File(root, "shared.json")
        val ui = PinnedTrustStore.sharedForFile(file)
        val receiver = PinnedTrustStore.sharedForFile(File(root, "./shared.json"))
        assertSame(ui, receiver)
        val peer = DeviceIdentity.generateEphemeral()
        val before = receiver.changes.value
        ui.enrollVerifiedPeer(peer.publicIdentity, "Peer", "macos", peer.publicKey)
        assertTrue(receiver.canTransfer(peer.publicIdentity))
        assertTrue(receiver.changes.value > before)
        receiver.updatePeerEndpoint(peer.publicIdentity, "192.0.2.42", 42433)
        assertEquals("192.0.2.42", ui.allEnrolledPeers().single().lastKnownIp)
        receiver.block(peer.publicIdentity)
        assertFalse(ui.canTransfer(peer.publicIdentity))
        ui.unpair(peer.publicIdentity)
        assertTrue(receiver.allEnrolledPeers().isEmpty())
    }
    @Test fun verifiedEnrollmentRequiresDurableStorageAndMatchingIdentity() = withDirectory { root ->
        val peer = DeviceIdentity.generateEphemeral()
        val other = DeviceIdentity.generateEphemeral()
        val file = File(root, "trust.json")
        val store = PinnedTrustStore(file)
        store.enrollVerifiedPeer(peer.publicIdentity, "Peer", "macos", peer.publicKey)
        assertTrue(PinnedTrustStore(file).canTransfer(peer.publicIdentity))
        rejects(NearsideErrorCode.TRUST_KEY_MISMATCH) {
            store.enrollVerifiedPeer(peer.publicIdentity, "Wrong", "macos", other.publicKey)
        }
        assertEquals(TrustResult.Success(peer.publicIdentity), store.validatePeer(peer.spkiDer))
        val previous = file.readBytes()
        assertTrue(file.delete())
        assertTrue(file.mkdir())
        rejects(NearsideErrorCode.TRUST_STORAGE_FAILED) {
            store.enrollVerifiedPeer(other.publicIdentity, "Other", "macos", other.publicKey)
        }
        assertFalse(store.canTransfer(other.publicIdentity))
        assertTrue(store.canTransfer(peer.publicIdentity))
        assertTrue(file.isDirectory)
        assertTrue(previous.isNotEmpty())
    }

    @Test fun corruptStorageIsPreservedAndLogsRedactedError() = withDirectory { root ->
        val file = File(root, "private-store.json")
        val payload = "private corrupt payload"
        file.writeText(payload)
        val lines = mutableListOf<String>()
        NearsideLogger.logHandler = { lines.add(it) }
        try {
            val store = PinnedTrustStore(file)
            val peer = DeviceIdentity.generateEphemeral()
            rejects(NearsideErrorCode.TRUST_STORAGE_FAILED) {
                store.enrollVerifiedPeer(peer.publicIdentity, "Peer", "macos", peer.publicKey)
            }
            assertFalse(store.canTransfer(peer.publicIdentity))
            assertEquals(payload, file.readText())
            assertTrue(lines.any { it.contains("NS-TRUST-004") })
            assertFalse(lines.joinToString().contains(root.path))
            assertFalse(lines.joinToString().contains(payload))
        } finally { NearsideLogger.logHandler = null }
    }

    @Test fun identityMismatchedStoredRecordCannotGrantTrust() = withDirectory { root ->
        val peer = DeviceIdentity.generateEphemeral()
        val other = DeviceIdentity.generateEphemeral()
        val file = File(root, "mismatch.json")
        val record = JSONObject().apply {
            put("identity", peer.publicIdentity); put("name", "Wrong"); put("platformRaw", "macos")
            put("spkiBase64", Base64.getEncoder().encodeToString(other.spkiDer)); put("enrolledAtMillis", 1L)
        }
        val original = JSONObject().put("records", JSONArray().put(record)).put("blocked", JSONArray()).toString()
        file.writeText(original)
        val store = PinnedTrustStore(file)
        assertFalse(store.canTransfer(peer.publicIdentity))
        assertTrue(store.allEnrolledPeers().isEmpty())
        assertEquals(original, file.readText())
    }

    @Test fun concurrentTransactionsPersistAllPinsBlocksAndEndpointUpdates() = withDirectory { root ->
        val file = File(root, "parallel.json")
        val store = PinnedTrustStore(file)
        val peers = (0 until 24).map { DeviceIdentity.generateEphemeral() }
        val executor = Executors.newFixedThreadPool(6)
        try {
            val tasks = peers.mapIndexed { index, peer -> executor.submit {
                store.enrollVerifiedPeer(peer.publicIdentity, "Peer", "macos", peer.publicKey)
                store.updatePeerEndpoint(peer.publicIdentity, "192.0.2.${index + 1}", 41433)
                if (index % 2 == 0) store.block(peer.publicIdentity)
                store.allEnrolledPeers()
            } }
            tasks.forEach { it.get(10, TimeUnit.SECONDS) }
        } finally { executor.shutdownNow() }
        val restored = PinnedTrustStore(file)
        assertEquals(peers.size, restored.allEnrolledPeers().size)
        peers.forEachIndexed { index, peer -> assertEquals(index % 2 != 0, restored.canTransfer(peer.publicIdentity)) }
        val snapshot = restored.allEnrolledPeers().first()
        snapshot.lastKnownIp = "mutated outside store"
        assertFalse(restored.allEnrolledPeers().any { it.lastKnownIp == "mutated outside store" })
    }

    private fun rejects(code: NearsideErrorCode, body: () -> Unit) {
        try { body(); fail("Expected ${code.code}") }
        catch (error: NearsideError) { assertEquals(code, error.code) }
    }
    private fun withDirectory(body: (File) -> Unit) {
        val root = Files.createTempDirectory("nearside-trust-tests").toFile()
        try { body(root) } finally { root.deleteRecursively() }
    }
}
