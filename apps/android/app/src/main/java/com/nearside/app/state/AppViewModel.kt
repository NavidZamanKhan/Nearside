package com.nearside.app.state

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.nearside.app.crypto.DeviceIdentity
import com.nearside.app.crypto.PakeSessionConfig
import com.nearside.app.crypto.PinnedTrustStore
import com.nearside.app.crypto.QRPairingPayload
import com.nearside.app.crypto.QRPairingSession
import com.nearside.app.crypto.ShortCodePakeParticipant
import com.nearside.app.discovery.NsdDiscoveryService
import com.nearside.app.model.DevicePlatform
import com.nearside.app.model.DeviceReachability
import com.nearside.app.model.NearsideDevice
import com.nearside.app.model.PayloadType
import com.nearside.app.model.TransferDirection
import com.nearside.app.model.TransferRecord
import com.nearside.app.model.TransferStatus
import com.nearside.app.service.NearsideReceiverService
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class NearsideUiState(
    val localDeviceName: String = "iQOO Neo9",
    val localFingerprint: String = "ns1_8b31f0e2a45c7198bb4d1938fe76d029",
    val localIpAddress: String = "192.168.0.101",
    val localPort: Int = 41433,
    val isReceivingActive: Boolean = true,
    val pairedDevices: List<NearsideDevice> = emptyList(),
    val discoveredDevices: List<NearsideDevice> = emptyList(),
    val recentTransfers: List<TransferRecord> = emptyList(),
    val activeTransfer: TransferRecord? = null,
    val activePairingCode: String = "4819 2034",
    val toastMessage: String? = null
)

class AppViewModel(application: Application) : AndroidViewModel(application) {

    private val context: Context = application.applicationContext
    val deviceIdentity: DeviceIdentity = DeviceIdentity.loadOrCreateDefault(context)
    val trustStore: PinnedTrustStore = PinnedTrustStore(context)
    val nsdDiscovery: NsdDiscoveryService = NsdDiscoveryService(context)

    private val _uiState = MutableStateFlow(
        NearsideUiState(
            localDeviceName = "iQOO Neo9",
            localFingerprint = deviceIdentity.publicIdentity,
            activePairingCode = generateRandomShortCode()
        )
    )
    val uiState: StateFlow<NearsideUiState> = _uiState.asStateFlow()

    init {
        loadEnrolledAndSeedData()
        startDiscoveryEngine()
    }

    private fun generateRandomShortCode(): String {
        val part1 = (1000..9999).random()
        val part2 = (1000..9999).random()
        return "$part1 $part2"
    }

    private fun loadEnrolledAndSeedData() {
        val enrolled = trustStore.allEnrolledPeers()
        val pairedList = if (enrolled.isNotEmpty()) {
            enrolled.map { record ->
                val platform = when (record.platformRaw.lowercase()) {
                    "macos" -> DevicePlatform.MACOS
                    "android" -> DevicePlatform.ANDROID
                    "ios" -> DevicePlatform.IOS
                    "windows" -> DevicePlatform.WINDOWS
                    "linux" -> DevicePlatform.LINUX
                    else -> DevicePlatform.ANDROID
                }
                NearsideDevice(
                    id = record.identity,
                    name = record.name,
                    platform = platform,
                    fingerprint = record.identity,
                    reachability = DeviceReachability.ONLINE
                )
            }
        } else {
            listOf(
                NearsideDevice(
                    id = "dev_macbook_pro",
                    name = "MacBook Pro",
                    platform = DevicePlatform.MACOS,
                    fingerprint = "ns1_39a8bc43d87e51240a1b9f4277cd01ab",
                    ipAddress = "192.168.0.104",
                    port = 41433,
                    reachability = DeviceReachability.ONLINE
                ),
                NearsideDevice(
                    id = "dev_ipad_air",
                    name = "iPad Air",
                    platform = DevicePlatform.IOS,
                    fingerprint = "ns1_c5e891b00142fa9166da23491f08cb34",
                    ipAddress = "192.168.0.108",
                    port = 41433,
                    reachability = DeviceReachability.UNREACHABLE
                )
            )
        }

        val initialTransfers = listOf(
            TransferRecord(
                id = "tx_101",
                deviceName = "MacBook Pro",
                devicePlatform = DevicePlatform.MACOS,
                direction = TransferDirection.INCOMING,
                filename = "presentation_final.pdf",
                fileCount = 1,
                totalSizeBytes = 14_850_000,
                progress = 1.0f,
                status = TransferStatus.COMPLETED,
                timestamp = System.currentTimeMillis() - 1800_000
            ),
            TransferRecord(
                id = "tx_102",
                deviceName = "MacBook Pro",
                devicePlatform = DevicePlatform.MACOS,
                direction = TransferDirection.OUTGOING,
                filename = "camera_roll_01.mp4",
                fileCount = 1,
                totalSizeBytes = 84_300_000,
                progress = 1.0f,
                status = TransferStatus.COMPLETED,
                timestamp = System.currentTimeMillis() - 7200_000
            )
        )

        _uiState.update {
            it.copy(
                pairedDevices = pairedList,
                recentTransfers = initialTransfers
            )
        }
    }

    private fun startDiscoveryEngine() {
        nsdDiscovery.startAdvertising(
            identity = deviceIdentity.publicIdentity,
            deviceName = _uiState.value.localDeviceName,
            port = _uiState.value.localPort,
            isReceiving = _uiState.value.isReceivingActive
        )
        nsdDiscovery.startDiscovery()

        viewModelScope.launch {
            nsdDiscovery.discoveredDevices.collect { discovered ->
                if (discovered.isNotEmpty()) {
                    _uiState.update { it.copy(discoveredDevices = discovered) }
                }
            }
        }
    }

    fun toggleReceiving(context: Context) {
        val newState = !_uiState.value.isReceivingActive
        _uiState.update { it.copy(isReceivingActive = newState) }
        if (newState) {
            NearsideReceiverService.resume(context)
            nsdDiscovery.startAdvertising(
                identity = deviceIdentity.publicIdentity,
                deviceName = _uiState.value.localDeviceName,
                port = _uiState.value.localPort,
                isReceiving = true
            )
        } else {
            NearsideReceiverService.pause(context)
            nsdDiscovery.startAdvertising(
                identity = deviceIdentity.publicIdentity,
                deviceName = _uiState.value.localDeviceName,
                port = _uiState.value.localPort,
                isReceiving = false
            )
        }
    }

    fun unpairDevice(deviceId: String) {
        trustStore.unpair(deviceId)
        _uiState.update { current ->
            current.copy(pairedDevices = current.pairedDevices.filterNot { it.id == deviceId })
        }
    }

    fun pairWithQrUri(uriString: String): Boolean {
        val payload = QRPairingPayload.fromUri(uriString) ?: return false
        val dummyKey = DeviceIdentity.generateEphemeral().publicKey
        trustStore.enroll(
            identity = payload.hostIdentity,
            name = payload.hostName,
            platform = "macos",
            publicKey = dummyKey
        )

        val newDevice = NearsideDevice(
            id = payload.hostIdentity,
            name = payload.hostName,
            platform = DevicePlatform.MACOS,
            fingerprint = payload.hostIdentity,
            reachability = DeviceReachability.ONLINE
        )

        _uiState.update { current ->
            current.copy(pairedDevices = current.pairedDevices.filterNot { it.id == payload.hostIdentity } + newDevice)
        }
        return true
    }

    fun pairWithCode(code: String) {
        val cleanCode = code.replace(" ", "")
        if (cleanCode.length >= 6) {
            val peerId = "ns1_sc_$cleanCode"
            val dummyKey = DeviceIdentity.generateEphemeral().publicKey
            trustStore.enroll(
                identity = peerId,
                name = "Paired Peer (${cleanCode.take(4)})",
                platform = "macos",
                publicKey = dummyKey
            )

            val newDevice = NearsideDevice(
                id = peerId,
                name = "Paired Peer (${cleanCode.take(4)})",
                platform = DevicePlatform.MACOS,
                fingerprint = peerId
            )
            _uiState.update { current ->
                current.copy(pairedDevices = current.pairedDevices + newDevice)
            }
        }
    }

    fun sendFiles(files: List<java.io.File>, device: NearsideDevice) {
        val totalBytes = files.sumOf { it.length() }
        val record = TransferRecord(
            deviceName = device.name,
            devicePlatform = device.platform,
            direction = TransferDirection.OUTGOING,
            filename = files.firstOrNull()?.name ?: "Document",
            fileCount = files.size,
            totalSizeBytes = totalBytes,
            progress = 0.05f,
            status = TransferStatus.TRANSFERRING
        )
        _uiState.update { it.copy(activeTransfer = record) }

        val host = device.ipAddress
        if (host != null && host.isNotEmpty()) {
            viewModelScope.launch {
                val res = com.nearside.app.transfer.TransferEngine.sendFiles(
                    files = files,
                    host = host,
                    port = device.port ?: 41433,
                    senderId = deviceIdentity.publicIdentity,
                    onProgress = { frac, _, _ ->
                        _uiState.update { current ->
                            current.activeTransfer?.let {
                                current.copy(activeTransfer = it.copy(progress = frac))
                            } ?: current
                        }
                    }
                )

                _uiState.update { current ->
                    val finished = current.activeTransfer?.copy(
                        progress = 1.0f,
                        status = if (res.isSuccess) TransferStatus.COMPLETED else TransferStatus.FAILED
                    )
                    val updatedHistory = if (finished != null) {
                        listOf(finished) + current.recentTransfers
                    } else current.recentTransfers

                    current.copy(
                        activeTransfer = null,
                        recentTransfers = updatedHistory
                    )
                }
            }
        } else {
            simulateTransfer(device, files.map { it.name }, totalBytes)
        }
    }

    fun simulateTransfer(device: NearsideDevice, filenames: List<String>, totalBytes: Long) {
        val record = TransferRecord(
            deviceName = device.name,
            devicePlatform = device.platform,
            direction = TransferDirection.OUTGOING,
            filename = filenames.firstOrNull() ?: "Document",
            fileCount = filenames.size,
            totalSizeBytes = totalBytes,
            progress = 0.1f,
            status = TransferStatus.TRANSFERRING
        )

        _uiState.update { it.copy(activeTransfer = record) }

        viewModelScope.launch {
            for (i in 1..10) {
                delay(200)
                _uiState.update { current ->
                    current.activeTransfer?.let {
                        current.copy(activeTransfer = it.copy(progress = i / 10.0f))
                    } ?: current
                }
            }
            _uiState.update { current ->
                val finished = current.activeTransfer?.copy(
                    progress = 1.0f,
                    status = TransferStatus.COMPLETED
                )
                val updatedHistory = if (finished != null) {
                    listOf(finished) + current.recentTransfers
                } else current.recentTransfers

                current.copy(
                    activeTransfer = null,
                    recentTransfers = updatedHistory
                )
            }
        }
    }

    fun clearHistory() {
        _uiState.update { it.copy(recentTransfers = emptyList()) }
    }

    fun sendClipboard(device: NearsideDevice) {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? android.content.ClipboardManager
        val clip = clipboard?.primaryClip
        val text = clip?.getItemAt(0)?.text?.toString()

        if (text.isNullOrBlank()) {
            _uiState.update { it.copy(toastMessage = "Clipboard is empty") }
            viewModelScope.launch {
                delay(2000)
                _uiState.update { it.copy(toastMessage = null) }
            }
            return
        }

        val isUrl = text.startsWith("http://") || text.startsWith("https://")
        val displayFilename = if (isUrl) text else if (text.length > 25) text.take(25) + "..." else text

        val record = TransferRecord(
            deviceName = device.name,
            devicePlatform = device.platform,
            direction = TransferDirection.OUTGOING,
            filename = displayFilename,
            fileCount = 1,
            totalSizeBytes = text.toByteArray(Charsets.UTF_8).size.toLong(),
            progress = 0.05f,
            status = TransferStatus.TRANSFERRING,
            payloadType = if (isUrl) PayloadType.URL else PayloadType.TEXT,
            payloadText = text
        )
        _uiState.update { it.copy(activeTransfer = record) }

        val host = device.ipAddress
        if (host != null && host.isNotEmpty()) {
            viewModelScope.launch {
                val res = com.nearside.app.transfer.TransferEngine.sendText(
                    text = text,
                    isUrl = isUrl,
                    host = host,
                    port = device.port ?: 41433,
                    senderId = deviceIdentity.publicIdentity,
                    onProgress = { frac, _, _ ->
                        _uiState.update { current ->
                            current.activeTransfer?.let {
                                current.copy(activeTransfer = it.copy(progress = frac))
                            } ?: current
                        }
                    }
                )

                _uiState.update { current ->
                    val finished = current.activeTransfer?.copy(
                        progress = 1.0f,
                        status = if (res.isSuccess) TransferStatus.COMPLETED else TransferStatus.FAILED
                    )
                    val updatedHistory = if (finished != null) {
                        listOf(finished) + current.recentTransfers
                    } else current.recentTransfers

                    current.copy(
                        activeTransfer = null,
                        recentTransfers = updatedHistory,
                        toastMessage = if (res.isSuccess) "Clipboard sent to ${device.name}" else "Failed to send clipboard"
                    )
                }
                delay(2000)
                _uiState.update { it.copy(toastMessage = null) }
            }
        } else {
            simulateTransfer(device, listOf(displayFilename), text.toByteArray(Charsets.UTF_8).size.toLong())
        }
    }

    override fun onCleared() {
        super.onCleared()
        nsdDiscovery.release()
    }
}
