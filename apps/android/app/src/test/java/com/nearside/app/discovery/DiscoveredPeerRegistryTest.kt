package com.nearside.app.discovery

import com.nearside.app.model.*
import org.junit.Assert.*
import org.junit.Test

class DiscoveredPeerRegistryTest {
    private fun peer(identity: String = "ns1_" + "a".repeat(64), ip: String = "192.168.1.2", time: Long = 1) =
        NearsideDevice(id = identity, fingerprint = identity, name = "MacBook", platform = DevicePlatform.MACOS, ipAddress = ip, port = 41433, lastSeenTimestamp = time)

    @Test fun aliasesProduceOnePeerAndNewestEndpointWins() {
        val registry = DiscoveredPeerRegistry()
        repeat(5) { i ->
            val name = "Nearside-MacBook ($i)"
            assertTrue(registry.resolved(name, registry.found(name), peer(ip = "192.168.1.${i + 2}", time = i.toLong())))
        }
        assertEquals(1, registry.devices().size)
        assertEquals("192.168.1.6", registry.devices().single().ipAddress)
        registry.lost("Nearside-MacBook (0)")
        assertEquals(1, registry.devices().size)
        repeat(5) { registry.lost("Nearside-MacBook ($it)") }
        assertTrue(registry.devices().isEmpty())
    }

    @Test fun lostOrRestartedServicesCannotResurrectFromLateResolution() {
        val registry = DiscoveredPeerRegistry()
        val lostToken = registry.found("alias")
        registry.lost("alias")
        assertFalse(registry.resolved("alias", lostToken, peer()))
        val newToken = registry.found("alias")
        assertFalse(registry.resolved("alias", lostToken, peer()))
        assertTrue(registry.resolved("alias", newToken, peer()))
        registry.clear()
        assertFalse(registry.resolved("alias", newToken, peer()))
        assertTrue(registry.devices().isEmpty())
    }

    @Test fun identicalDisplayNamesKeepDifferentIdentities() {
        val registry = DiscoveredPeerRegistry()
        registry.resolved("first", registry.found("first"), peer())
        registry.resolved("second", registry.found("second"), peer(identity = "ns1_" + "b".repeat(64)))
        assertEquals(2, registry.devices().size)
    }

    @Test fun aliasCanChangeIdentityWithoutLeavingGhostDevice() {
        val registry = DiscoveredPeerRegistry()
        registry.resolved("alias", registry.found("alias"), peer())
        registry.resolved("alias", registry.found("alias"), peer(identity = "ns1_" + "b".repeat(64)))
        assertEquals("ns1_" + "b".repeat(64), registry.devices().single().id)
    }

    @Test fun failedOldResolutionDoesNotDiscardNewRegistration() {
        val registry = DiscoveredPeerRegistry()
        val old = registry.found("alias")
        val current = registry.found("alias")
        registry.resolved("alias", current, peer())
        registry.discard("alias", old)
        assertEquals(1, registry.devices().size)
        registry.discard("alias", current)
        assertTrue(registry.devices().isEmpty())
    }

    @Test fun uiDeduplicatesByIdentityWithoutMergingNames() {
        assertEquals(2, deduplicateDevicesByIdentity(listOf(peer(), peer(time = 3), peer(identity = "ns1_" + "b".repeat(64)))).size)
        assertEquals(3L, deduplicateDevicesByIdentity(listOf(peer(), peer(time = 3))).single().lastSeenTimestamp)
    }
}
