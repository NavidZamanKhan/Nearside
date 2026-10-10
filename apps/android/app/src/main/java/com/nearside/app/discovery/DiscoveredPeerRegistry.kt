package com.nearside.app.discovery

import com.nearside.app.model.NearsideDevice

/** Service aliases are transport records; only the persistent TXT identity defines a peer. */
internal class DiscoveredPeerRegistry {
    private data class Registration(val token: Long, val device: NearsideDevice? = null)
    private val registrations = mutableMapOf<String, Registration>()
    private var nextToken = 0L

    @Synchronized fun found(serviceKey: String): Long {
        val token = ++nextToken
        registrations[serviceKey] = Registration(token, registrations[serviceKey]?.device)
        return token
    }

    @Synchronized fun resolved(serviceKey: String, token: Long, device: NearsideDevice): Boolean {
        if (registrations[serviceKey]?.token != token || device.id.isBlank() || device.id != device.fingerprint) return false
        registrations[serviceKey] = Registration(token, device)
        return true
    }

    @Synchronized fun lost(serviceKey: String) { registrations.remove(serviceKey) }
    @Synchronized fun discard(serviceKey: String, token: Long) {
        if (registrations[serviceKey]?.token == token) registrations.remove(serviceKey)
    }
    @Synchronized fun clear() { registrations.clear() }
    @Synchronized fun devices(): List<NearsideDevice> = deduplicateDevicesByIdentity(registrations.values.mapNotNull { it.device })
}

/** Defence at the state/UI boundary also covers older or cached service snapshots. */
fun deduplicateDevicesByIdentity(devices: List<NearsideDevice>): List<NearsideDevice> = devices
    .filter { it.fingerprint.isNotBlank() || it.id.isNotBlank() }
    .groupBy { it.fingerprint.ifBlank { it.id } }
    .values.map { peers -> peers.maxBy { it.lastSeenTimestamp } }
    .sortedWith(compareBy({ it.name }, { it.fingerprint.ifBlank { it.id } }))
