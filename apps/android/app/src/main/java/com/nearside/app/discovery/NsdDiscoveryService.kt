package com.nearside.app.discovery

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.LinkProperties
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.nearside.app.diagnostics.*
import com.nearside.app.model.DevicePlatform
import com.nearside.app.model.DeviceReachability
import com.nearside.app.model.NearsideDevice
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.delay
import java.lang.ref.WeakReference

class NsdDiscoveryService(context: Context) {

    companion object {
        private const val TAG = "NearsideNSD"
        private const val SERVICE_TYPE = "_nearside._tcp."

        @Volatile private var globalDiscoveredDevices = emptyMap<String, NearsideDevice>()
        @Volatile private var activeDiscovery = WeakReference<NsdDiscoveryService>(null)

        fun findDiscoveredDevice(identity: String): NearsideDevice? {
            return globalDiscoveredDevices[identity]?.takeIf { it.id == identity && it.fingerprint == identity }
        }

        suspend fun refreshDiscoveredDevice(identity: String, timeoutMs: Long = 2000): NearsideDevice? {
            val discovery = activeDiscovery.get() ?: return null
            val before = findDiscoveredDevice(identity)?.lastSeenTimestamp ?: 0L
            discovery.handler.post {
                discovery.activeServices.values.toList().forEach { discovery.resolveService(it) }
            }
            val deadline = System.nanoTime() + timeoutMs.coerceIn(0, 5000) * 1_000_000
            while (System.nanoTime() < deadline) {
                val peer = findDiscoveredDevice(identity)
                if (peer != null && peer.lastSeenTimestamp > before) return peer
                delay(50)
            }
            return findDiscoveredDevice(identity)
        }
    }

    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager

    private var registrationListener: NsdManager.RegistrationListener? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null

    private val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var observedNetwork: Network? = null
    private var observedAddresses = emptyList<String>()
    private var discoveryRequested = false
    private var advertisedPort = 41433
    private val restartOnNetworkChange = Runnable {
        if (discoveryRequested) {
            val advertised = registrationListener != null
            startDiscoveryOnMain()
            if (advertised) startAdvertising(localIdentity, localDeviceName, advertisedPort, isReceivingActive)
        }
    }

    private fun monitorNetwork() {
        if (networkCallback != null) return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (!discoveryRequested) return
                if (observedNetwork != network) {
                    observedNetwork = network
                    observedAddresses = emptyList()
                    scheduleNetworkRestart()
                }
            }
            override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
                if (!discoveryRequested || observedNetwork != network) return
                val addresses = properties.linkAddresses.map { it.toString() }.sorted()
                if (addresses != observedAddresses) {
                    observedAddresses = addresses
                    scheduleNetworkRestart()
                }
            }
            override fun onLost(network: Network) {
                if (!discoveryRequested || observedNetwork != network) return
                observedNetwork = null
                observedAddresses = emptyList()
                handler.removeCallbacks(restartOnNetworkChange)
                stopDiscoveryOnMain()
            }
        }
        try {
            connectivity.registerDefaultNetworkCallback(callback, handler)
            networkCallback = callback
        } catch (error: RuntimeException) {
            NearsideLogger.warn("discovery", "monitorNetwork", "Network change monitoring unavailable", state = "browsing", errorCode = NearsideErrorCode.DISCOVERY_BROWSER_FAILED, underlyingError = error)
        }
    }

    private fun scheduleNetworkRestart() {
        // Immediately invalidate old addresses and late resolution callbacks, then debounce OS events.
        stopDiscoveryOnMain()
        handler.removeCallbacks(restartOnNetworkChange)
        handler.postDelayed(restartOnNetworkChange, 300)
    }

    private fun stopNetworkMonitor() {
        handler.removeCallbacks(restartOnNetworkChange)
        networkCallback?.let { callback ->
            try { connectivity.unregisterNetworkCallback(callback) }
            catch (error: RuntimeException) {
                NearsideLogger.warn("discovery", "stopNetworkMonitor", "Unable to release network callback", underlyingError = error)
            }
        }
        networkCallback = null
        observedNetwork = null
        observedAddresses = emptyList()
    }

    private var localIdentity: String = ""
    private var localDeviceName: String = ""
    private var isReceivingActive: Boolean = true

    private val handler = Handler(Looper.getMainLooper())
    private val registry = DiscoveredPeerRegistry()
    private val activeServices = mutableMapOf<String, NsdServiceInfo>()
    private val pendingResolutions = ArrayDeque<Pair<NsdServiceInfo, Long>>()
    private var resolving = false
    private var activeResolutionToken: Long? = null
    private var activeResolveListener: NsdManager.ResolveListener? = null
    private var resolutionDeadline: Runnable? = null

    private fun finishResolution(token: Long): Boolean {
        if (activeResolutionToken != token) return false
        resolutionDeadline?.let { handler.removeCallbacks(it) }
        resolutionDeadline = null
        activeResolutionToken = null
        activeResolveListener = null
        resolving = false
        return true
    }

    private fun cancelResolution() {
        val token = activeResolutionToken ?: return
        val listener = activeResolveListener
        if (Build.VERSION.SDK_INT < 34) {
            // These OS versions cannot cancel a native resolution. Keep its slot until the
            // terminal callback, so queued peers aren't rejected with ALREADY_ACTIVE.
            resolutionDeadline?.let { handler.removeCallbacks(it) }
            resolutionDeadline = null
            return
        }
        finishResolution(token)
        if (listener != null) {
            try { nsdManager.stopServiceResolution(listener) }
            catch (error: RuntimeException) {
                NearsideLogger.debug("discovery", "cancelResolution", "Resolution already finished", correlationId = "disc_$token")
            }
        }
    }
    private var discoveryGeneration = 0L
    private var lastSeenTime = 0L

    private fun serviceKey(service: NsdServiceInfo) = "${service.serviceName}|${service.serviceType}"

    private fun publishDevices() {
        val devices = registry.devices()
        if (activeDiscovery.get() === this) {
            globalDiscoveredDevices = devices.associateBy { it.id }
        }
        _discoveredDevices.value = devices
    }
    private val _discoveredDevices = MutableStateFlow<List<NearsideDevice>>(emptyList())
    val discoveredDevices = _discoveredDevices.asStateFlow()

    fun startAdvertising(
        identity: String,
        deviceName: String,
        port: Int = 41433,
        isReceiving: Boolean = true
    ) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            handler.post { startAdvertising(identity, deviceName, port, isReceiving) }
            return
        }
        this.advertisedPort = port
        this.localIdentity = identity
        this.localDeviceName = deviceName
        this.isReceivingActive = isReceiving

        stopAdvertising()

        val serviceInfo = NsdServiceInfo().apply {
            serviceName = "Nearside-${deviceName.replace(" ", "-").replace("'", "")}"
            serviceType = SERVICE_TYPE
            setPort(port)
            setAttribute("v", "1")
            setAttribute("id", identity)
            setAttribute("name", deviceName)
            setAttribute("os", "android")
            setAttribute("pair", "1")
            setAttribute("recv", if (isReceiving) "1" else "0")
            val localIp = getLocalWifiIp()
            if (localIp.isNotEmpty() && localIp != "127.0.0.1") {
                setAttribute("ip", localIp)
            }
            setAttribute("port", port.toString())
        }

        registrationListener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(service: NsdServiceInfo) {
                Log.i(TAG, "NSD advertisement registered: ${service.serviceName}")
                NearsideLogger.info("discovery", "registerService", "NSD advertisement registered: ${service.serviceName}", state = "advertising")
            }

            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "NSD advertisement registration failed: $errorCode")
                val err = NearsideError(NearsideErrorCode.DISCOVERY_REGISTRATION_FAILED, "registerService", "NSD registration failed: $errorCode")
                NearsideLogger.error(err, state = "failed")
            }

            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {
                Log.i(TAG, "NSD advertisement unregistered")
                NearsideLogger.info("discovery", "unregisterService", "NSD advertisement unregistered", state = "stopped")
            }

            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "NSD advertisement unregistration failed: $errorCode")
                NearsideLogger.warn("discovery", "unregisterService", "NSD advertisement unregistration failed: $errorCode")
            }
        }

        try {
            nsdManager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, registrationListener)
        } catch (e: Exception) {
            Log.e(TAG, "Error registering NSD service", e)
            val err = NearsideError(NearsideErrorCode.DISCOVERY_REGISTRATION_FAILED, "registerService", "Error registering NSD service: ${e.message}", underlyingError = e)
            NearsideLogger.error(err, state = "failed")
        }
    }

    fun stopAdvertising() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            handler.post { stopAdvertising() }
            return
        }
        registrationListener?.let { listener ->
            try {
                nsdManager.unregisterService(listener)
            } catch (e: Exception) {
                Log.e(TAG, "Error unregistering NSD service", e)
            }
            registrationListener = null
        }
    }

    fun startDiscovery() = handler.post {
        discoveryRequested = true
        monitorNetwork()
        startDiscoveryOnMain()
    }

    private fun startDiscoveryOnMain() {
        stopDiscoveryOnMain()
        activeDiscovery = WeakReference(this)
        val generation = discoveryGeneration

        discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "Discovery start failed: $errorCode")
                val err = NearsideError(NearsideErrorCode.DISCOVERY_BROWSER_FAILED, "startDiscovery", "Discovery start failed: $errorCode")
                NearsideLogger.error(err, state = "failed")
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "Discovery stop failed: $errorCode")
                NearsideLogger.warn("discovery", "stopDiscovery", "Discovery stop failed: $errorCode")
            }

            override fun onDiscoveryStarted(serviceType: String) {
                Log.i(TAG, "Discovery started for $serviceType")
                NearsideLogger.info("discovery", "startDiscovery", "Discovery started for $serviceType", state = "browsing")
            }

            override fun onDiscoveryStopped(serviceType: String) {
                Log.i(TAG, "Discovery stopped for $serviceType")
                NearsideLogger.info("discovery", "stopDiscovery", "Discovery stopped for $serviceType", state = "stopped")
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                Log.i(TAG, "Service found: ${serviceInfo.serviceName}")
                NearsideLogger.debug("discovery", "onServiceFound", "Discovered service: ${serviceInfo.serviceName}")
                handler.post {
                    if (generation == discoveryGeneration && discoveryListener != null) {
                        activeServices[serviceKey(serviceInfo)] = serviceInfo
                        resolveService(serviceInfo)
                    }
                }
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                Log.i(TAG, "Service lost: ${serviceInfo.serviceName}")
                NearsideLogger.debug("discovery", "onServiceLost", "Lost service: ${serviceInfo.serviceName}")
                handler.post {
                    if (generation == discoveryGeneration) {
                        activeServices.remove(serviceKey(serviceInfo))
                        registry.lost(serviceKey(serviceInfo))
                        publishDevices()
                    }
                }
            }
        }

        try {
            nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
        } catch (e: Exception) {
            Log.e(TAG, "Error starting discovery", e)
            val err = NearsideError(NearsideErrorCode.DISCOVERY_BROWSER_FAILED, "startDiscovery", "Error starting discovery: ${e.message}", underlyingError = e)
            NearsideLogger.error(err, state = "failed")
        }
    }

    private fun resolveService(serviceInfo: NsdServiceInfo) {
        val token = registry.found(serviceKey(serviceInfo))
        pendingResolutions.removeAll { serviceKey(it.first) == serviceKey(serviceInfo) }
        pendingResolutions.addLast(serviceInfo to token)
        resolveNextService()
    }

    // Legacy NsdManager accepts only one outstanding resolution at a time.
    private fun resolveNextService() {
        if (resolving || pendingResolutions.isEmpty()) return
        val (serviceInfo, token) = pendingResolutions.removeFirst()
        if (!activeServices.containsKey(serviceKey(serviceInfo))) { resolveNextService(); return }
        resolving = true
        activeResolutionToken = token
        val resolveListener = object : NsdManager.ResolveListener {
            override fun onResolveFailed(service: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "Resolve failed for ${service.serviceName}: $errorCode")
                NearsideLogger.warn("discovery", "resolveService", "Service resolution failed", state = "resolving", correlationId = "disc_$token", errorCode = NearsideErrorCode.DISCOVERY_RESOLVE_FAILED, metadata = mapOf("nativeCode" to errorCode.toString()))
                handler.post {
                    if (finishResolution(token)) {
                        registry.discard(serviceKey(serviceInfo), token)
                        publishDevices()
                        resolveNextService()
                    }
                }
            }

            override fun onServiceResolved(service: NsdServiceInfo) { handler.post {
                if (!finishResolution(token)) return@post
                resolveNextService()
                val attributes = service.attributes
                val idAttr = attributes["id"]?.let { String(it, Charsets.UTF_8) }
                if (idAttr == null || !idAttr.matches(Regex("ns1_[0-9a-f]{64}"))) {
                    NearsideLogger.warn("discovery", "resolveService", "Service has no valid persistent identity", state = "discarded", correlationId = "disc_$token", errorCode = NearsideErrorCode.DISCOVERY_RESOLVE_FAILED)
                    registry.discard(serviceKey(serviceInfo), token)
                    publishDevices()
                    return@post
                }
                val nameAttr = attributes["name"]?.let { String(it, Charsets.UTF_8) } ?: service.serviceName
                val osAttr = attributes["os"]?.let { String(it, Charsets.UTF_8) } ?: "unknown"
                val recvAttr = attributes["recv"]?.let { String(it, Charsets.UTF_8) } ?: "1"

                if (localIdentity.isNotEmpty() && idAttr == localIdentity) {
                    registry.discard(serviceKey(serviceInfo), token)
                    publishDevices()
                    return@post // Ignore our own broadcast
                }

                val platform = when (osAttr.lowercase()) {
                    "macos" -> DevicePlatform.MACOS
                    "android" -> DevicePlatform.ANDROID
                    "ios" -> DevicePlatform.IOS
                    "windows" -> DevicePlatform.WINDOWS
                    "linux" -> DevicePlatform.LINUX
                    else -> DevicePlatform.ANDROID
                }

                val hostAddress = service.host?.hostAddress
                val resolvedPort = service.port
                if (hostAddress.isNullOrBlank() || resolvedPort !in 1..65535) {
                    registry.discard(serviceKey(serviceInfo), token)
                    publishDevices()
                    return@post
                }
                val reachability = if (recvAttr == "1") DeviceReachability.ONLINE else DeviceReachability.BUSY

                lastSeenTime = maxOf(System.currentTimeMillis(), lastSeenTime + 1)
                val device = NearsideDevice(
                    id = idAttr,
                    name = nameAttr,
                    platform = platform,
                    fingerprint = idAttr,
                    ipAddress = hostAddress,
                    port = resolvedPort,
                    reachability = reachability,
                    lastSeenTimestamp = lastSeenTime
                )

                if (registry.resolved(serviceKey(serviceInfo), token, device)) publishDevices()
            } }
        }

        activeResolveListener = resolveListener
        val deadline = Runnable {
            if (activeResolutionToken == token) {
                cancelResolution()
                registry.discard(serviceKey(serviceInfo), token)
                publishDevices()
                NearsideLogger.warn("discovery", "resolveService", "Service resolution timed out", state = "failed", correlationId = "disc_$token", errorCode = NearsideErrorCode.DISCOVERY_RESOLVE_FAILED)
                resolveNextService()
            }
        }
        resolutionDeadline = deadline
        handler.postDelayed(deadline, 3000)
        try {
            nsdManager.resolveService(serviceInfo, resolveListener)
        } catch (e: Exception) {
            finishResolution(token)
            registry.discard(serviceKey(serviceInfo), token)
            publishDevices()
            NearsideLogger.warn("discovery", "resolveService", "Unable to start service resolution", state = "failed", correlationId = "disc_$token", errorCode = NearsideErrorCode.DISCOVERY_RESOLVE_FAILED, underlyingError = e)
            resolveNextService()
        }
    }

    fun stopDiscovery() = handler.post {
        discoveryRequested = false
        stopNetworkMonitor()
        stopDiscoveryOnMain()
    }

    private fun stopDiscoveryOnMain() {
        discoveryGeneration++
        cancelResolution()
        activeServices.clear()
        pendingResolutions.clear()
        registry.clear()
        discoveryListener?.let { listener ->
            try {
                nsdManager.stopServiceDiscovery(listener)
            } catch (e: Exception) {
                Log.e(TAG, "Error stopping discovery", e)
            }
            discoveryListener = null
        }
        publishDevices()
        if (activeDiscovery.get() === this) activeDiscovery.clear()
    }

    fun release() {
        stopAdvertising()
        stopDiscovery()
    }
}

fun getLocalWifiIp(): String {
    try {
        val interfaces = java.net.NetworkInterface.getNetworkInterfaces()
        while (interfaces.hasMoreElements()) {
            val networkInterface = interfaces.nextElement()
            val addresses = networkInterface.inetAddresses
            while (addresses.hasMoreElements()) {
                val address = addresses.nextElement()
                if (!address.isLoopbackAddress && address is java.net.Inet4Address) {
                    return address.hostAddress ?: ""
                }
            }
        }
    } catch (_: Exception) {}
    return "127.0.0.1"
}
