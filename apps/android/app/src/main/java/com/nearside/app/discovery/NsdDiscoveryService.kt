package com.nearside.app.discovery

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.util.Log
import com.nearside.app.diagnostics.*
import com.nearside.app.model.DevicePlatform
import com.nearside.app.model.DeviceReachability
import com.nearside.app.model.NearsideDevice
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.ConcurrentHashMap

class NsdDiscoveryService(context: Context) {

    companion object {
        private const val TAG = "NearsideNSD"
        private const val SERVICE_TYPE = "_nearside._tcp."
    }

    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager

    private var registrationListener: NsdManager.RegistrationListener? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null

    private var localIdentity: String = ""
    private var localDeviceName: String = ""
    private var isReceivingActive: Boolean = true

    private val discoveredMap = ConcurrentHashMap<String, NearsideDevice>()
    private val _discoveredDevices = MutableStateFlow<List<NearsideDevice>>(emptyList())
    val discoveredDevices = _discoveredDevices.asStateFlow()

    fun startAdvertising(
        identity: String,
        deviceName: String,
        port: Int = 41433,
        isReceiving: Boolean = true
    ) {
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
        registrationListener?.let { listener ->
            try {
                nsdManager.unregisterService(listener)
            } catch (e: Exception) {
                Log.e(TAG, "Error unregistering NSD service", e)
            }
            registrationListener = null
        }
    }

    fun startDiscovery() {
        stopDiscovery()
        discoveredMap.clear()
        _discoveredDevices.value = emptyList()

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
                resolveService(serviceInfo)
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                Log.i(TAG, "Service lost: ${serviceInfo.serviceName}")
                NearsideLogger.debug("discovery", "onServiceLost", "Lost service: ${serviceInfo.serviceName}")
                discoveredMap.remove(serviceInfo.serviceName)
                _discoveredDevices.value = discoveredMap.values.toList()
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
        val resolveListener = object : NsdManager.ResolveListener {
            override fun onResolveFailed(service: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "Resolve failed for ${service.serviceName}: $errorCode")
                NearsideLogger.warn("discovery", "resolveService", "Resolve failed for ${service.serviceName}: $errorCode", errorCode = NearsideErrorCode.DISCOVERY_RESOLVE_FAILED)
            }

            override fun onServiceResolved(service: NsdServiceInfo) {
                val attributes = service.attributes
                val idAttr = attributes["id"]?.let { String(it, Charsets.UTF_8) } ?: service.serviceName
                val nameAttr = attributes["name"]?.let { String(it, Charsets.UTF_8) } ?: service.serviceName
                val osAttr = attributes["os"]?.let { String(it, Charsets.UTF_8) } ?: "unknown"
                val recvAttr = attributes["recv"]?.let { String(it, Charsets.UTF_8) } ?: "1"

                if (localIdentity.isNotEmpty() && idAttr == localIdentity) {
                    return // Ignore our own broadcast
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
                val port = service.port
                val reachability = if (recvAttr == "1") DeviceReachability.ONLINE else DeviceReachability.BUSY

                val device = NearsideDevice(
                    id = idAttr,
                    name = nameAttr,
                    platform = platform,
                    fingerprint = idAttr,
                    ipAddress = hostAddress,
                    port = port,
                    reachability = reachability,
                    lastSeenTimestamp = System.currentTimeMillis()
                )

                discoveredMap[service.serviceName] = device
                _discoveredDevices.value = discoveredMap.values.toList()
            }
        }

        try {
            nsdManager.resolveService(serviceInfo, resolveListener)
        } catch (e: Exception) {
            Log.e(TAG, "Error resolving service ${serviceInfo.serviceName}", e)
        }
    }

    fun stopDiscovery() {
        discoveryListener?.let { listener ->
            try {
                nsdManager.stopServiceDiscovery(listener)
            } catch (e: Exception) {
                Log.e(TAG, "Error stopping discovery", e)
            }
            discoveryListener = null
        }
        discoveredMap.clear()
        _discoveredDevices.value = emptyList()
    }

    fun release() {
        stopAdvertising()
        stopDiscovery()
    }
}
