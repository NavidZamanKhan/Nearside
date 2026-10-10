package com.nearside.app.transfer

import com.nearside.app.crypto.DeviceIdentity
import com.nearside.app.crypto.PinnedTrustStore
import com.nearside.app.model.DevicePlatform
import com.nearside.app.model.NearsideDevice
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

class EndpointRecoveryTest {
    private val stale = PeerEndpoint("192.0.2.10", 41433)
    private val fresh = PeerEndpoint("192.0.2.20", 42433)
    private val policy = RetryPolicy(maxAttempts = 3, initialDelayMs = 0)

    @Test fun liveDiscoveryWinsOverSavedEndpoint() = runBlocking {
        val seen = mutableListOf<PeerEndpoint>()
        val result = retryPeerEndpoint(stale, policy, { fresh }, { null }, {
            seen += it
            Result.success("sent")
        })
        assertTrue(result.isSuccess)
        assertEquals(listOf(fresh), seen)
    }

    @Test fun staleEndpointFailureRefreshesAndCachesSuccessfulAddress() = runBlocking {
        val seen = mutableListOf<PeerEndpoint>()
        var cached: PeerEndpoint? = null
        var refreshes = 0
        val result = retryPeerEndpoint(stale, policy, { null }, { refreshes++; fresh }, {
            seen += it
            if (it == stale) throw IOException("stale address")
            Result.success("sent")
        }, onSuccess = { cached = it })
        assertTrue(result.isSuccess)
        assertEquals(listOf(stale, fresh), seen)
        assertEquals(1, refreshes)
        assertEquals(fresh, cached)
    }

    @Test fun retryExhaustionIsBoundedAndRetainsNativeError() = runBlocking {
        var attempts = 0
        var refreshes = 0
        val nativeError = IOException("offline")
        val result = retryPeerEndpoint<String>(stale, policy, { null }, { refreshes++; null }, {
            attempts++
            throw nativeError
        })
        assertEquals(3, attempts)
        assertEquals(2, refreshes)
        assertSame(nativeError, result.exceptionOrNull())
    }

    @Test fun receiverRejectionDoesNotRefreshOrRetry() = runBlocking {
        var attempts = 0
        var refreshes = 0
        val rejection = IllegalStateException("untrusted recipient")
        val result = retryPeerEndpoint(stale, policy, { null }, { refreshes++; fresh }, {
            attempts++
            Result.failure<String>(rejection)
        })
        assertSame(rejection, result.exceptionOrNull())
        assertEquals(1, attempts)
        assertEquals(0, refreshes)
    }

    @Test fun discoveryCannotSubstituteAnotherIdentityOrInvalidEndpoint() {
        val device = NearsideDevice(id = "peer-a", fingerprint = "peer-a", name = "MacBook",
            platform = DevicePlatform.MACOS, ipAddress = fresh.host, port = fresh.port)
        assertEquals(fresh, PeerEndpoint.fromDiscovery("peer-a", device))
        assertNull(PeerEndpoint.fromDiscovery("peer-b", device))
        assertNull(PeerEndpoint.fromDiscovery("peer-a", device.copy(fingerprint = "peer-b")))
        assertNull(PeerEndpoint.fromDiscovery("peer-a", device.copy(port = 65536)))
        assertNull(PeerEndpoint.fromDiscovery("peer-a", device.copy(ipAddress = "")))
    }

    @Test fun endpointUpdatesPreservePinnedKeyAndCannotUnblockPeer() {
        val store = PinnedTrustStore()
        val identity = DeviceIdentity.generateEphemeral()
        store.enroll(identity.publicIdentity, "MacBook", "macos", identity.publicKey)
        store.updatePeerEndpoint(identity.publicIdentity, stale.host, stale.port)
        store.updatePeerEndpoint(identity.publicIdentity, fresh.host, fresh.port)
        val record = store.allEnrolledPeers().single()
        assertEquals(identity.publicIdentity, record.identity)
        assertEquals(fresh.host, record.lastKnownIp)
        assertEquals(java.util.Base64.getEncoder().encodeToString(identity.spkiDer), record.spkiBase64)
        assertTrue(store.canTransfer(identity.publicIdentity))
        store.block(identity.publicIdentity)
        store.updatePeerEndpoint(identity.publicIdentity, stale.host, stale.port)
        assertFalse(store.canTransfer(identity.publicIdentity))
        assertTrue(store.isBlocked(identity.publicIdentity))
    }
}
