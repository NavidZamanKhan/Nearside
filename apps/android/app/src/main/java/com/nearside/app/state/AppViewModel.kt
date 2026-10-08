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
import kotlinx.coroutines.Dispatchers
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
        viewModelScope.launch(Dispatchers.IO) {
            loadEnrolledAndSeedData()
            startDiscoveryEngine()
        }
    }

    private fun generateRandomShortCode(): String {
        val part1 = (1000..9999).random()
        val part2 = (1000..9999).random()
        return "$part1 $part2"
    }

    private fun loadEnrolledAndSeedData() {
        val enrolled = trustStore.allEnrolledPeers()
        val pairedList = enrolled.map { record ->
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

        _uiState.update {
            it.copy(
                pairedDevices = pairedList,
                recentTransfers = emptyList()
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
                    _uiState.update { current ->
                        val updatedPaired = current.pairedDevices.map { paired ->
                            val match = discovered.find { it.id == paired.id || it.fingerprint == paired.fingerprint }
                            if (match != null && match.ipAddress != null) {
                                paired.copy(
                                    ipAddress = match.ipAddress,
                                    port = match.port,
                                    reachability = match.reachability
                                )
                            } else paired
                        }
                        current.copy(
                            discoveredDevices = discovered,
                            pairedDevices = updatedPaired
                        )
                    }
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
            nsdDiscovery.stopAdvertising()
        }
    }

    fun cancelTransfer(transferId: String) {
        com.nearside.app.transfer.TransferEngine.cancelTransfer(transferId)
        NearsideReceiverService.cancelActiveTransfer(context, transferId)
        _uiState.update { current ->
            val cancelled = current.activeTransfer?.let {
                if (it.id == transferId) {
                    it.copy(
                        status = TransferStatus.CANCELLED,
                        errorMessage = "Transfer cancelled by user"
                    )
                } else null
            }
            current.copy(
                activeTransfer = null,
                recentTransfers = if (cancelled != null) listOf(cancelled) + current.recentTransfers else current.recentTransfers
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

    fun pairDiscoveredDevice(device: NearsideDevice) {
        val dummyKey = DeviceIdentity.generateEphemeral().publicKey
        trustStore.enroll(
            identity = device.id,
            name = device.name,
            platform = device.platform.name.lowercase(),
            publicKey = dummyKey
        )
        _uiState.update { current ->
            current.copy(
                pairedDevices = current.pairedDevices.filterNot { it.id == device.id } + device
            )
        }
    }

    fun pairWithCode(code: String) {
        val cleanCode = code.replace(" ", "")
        if (cleanCode.length >= 6) {
            val nearbyPeer = _uiState.value.discoveredDevices.firstOrNull { disc ->
                _uiState.value.pairedDevices.none { it.id == disc.id }
            }
            if (nearbyPeer != null) {
                pairDiscoveredDevice(nearbyPeer)
                return
            }

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
        if (!trustStore.isEnrolled(device.id)) {
            pairDiscoveredDevice(device)
        }

        val totalBytes = files.sumOf { it.length() }
        val record = TransferRecord(
            deviceName = device.name,
            devicePlatform = device.platform,
            direction = TransferDirection.OUTGOING,
            filename = files.firstOrNull()?.name ?: "Document",
            fileCount = files.size,
            totalSizeBytes = totalBytes,
            progress = 0.05f,
            speedBytesPerSec = 0.0,
            etaSeconds = null,
            status = TransferStatus.TRANSFERRING
        )
        _uiState.update { it.copy(activeTransfer = record) }

        val resolved = if (device.ipAddress.isNullOrEmpty()) {
            val disc = com.nearside.app.discovery.NsdDiscoveryService.findDiscoveredDevice(device.id)
                ?: com.nearside.app.discovery.NsdDiscoveryService.findDiscoveredDevice(device.fingerprint)
                ?: _uiState.value.discoveredDevices.firstOrNull { it.id == device.id || it.fingerprint == device.fingerprint }
                ?: _uiState.value.discoveredDevices.firstOrNull()
            if (disc != null && !disc.ipAddress.isNullOrEmpty()) {
                device.copy(ipAddress = disc.ipAddress, port = disc.port)
            } else device
        } else device

        val host = resolved.ipAddress ?: "127.0.0.1"
        viewModelScope.launch {
            val res = com.nearside.app.transfer.TransferEngine.sendFiles(
                files = files,
                host = host,
                port = resolved.port ?: 41433,
                senderId = deviceIdentity.publicIdentity,
                    onProgress = { frac, _, _ -> },
                    onProgressMetrics = { frac, bytesSent, total, speed, eta ->
                        _uiState.update { current ->
                            current.activeTransfer?.let {
                                current.copy(
                                    activeTransfer = it.copy(
                                        progress = frac,
                                        speedBytesPerSec = speed,
                                        etaSeconds = eta
                                    )
                                )
                            } ?: current
                        }
                    }
                )

                _uiState.update { current ->
                    val failureException = res.exceptionOrNull()
                    val nearsideErr = failureException as? com.nearside.app.diagnostics.NearsideError
                    val isCancelled = current.activeTransfer?.status == TransferStatus.CANCELLED ||
                            com.nearside.app.transfer.TransferEngine.isTransferCancelled(record.id)
                    val status = when {
                        isCancelled -> TransferStatus.CANCELLED
                        res.isSuccess -> TransferStatus.COMPLETED
                        else -> TransferStatus.FAILED
                    }
                    val errorCode = nearsideErr?.code?.code ?: (if (res.isSuccess) null else com.nearside.app.diagnostics.NearsideErrorCode.TRANSFER_INTERRUPTED.code)
                    val errorMessage = failureException?.message

                    val finished = current.activeTransfer?.copy(
                        progress = if (res.isSuccess) 1.0f else current.activeTransfer.progress,
                        speedBytesPerSec = 0.0,
                        etaSeconds = 0L,
                        status = status,
                        errorCode = errorCode,
                        errorMessage = errorMessage,
                        correlationId = current.activeTransfer.id
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

    fun simulateTransfer(device: NearsideDevice, filenames: List<String>, totalBytes: Long) {
        val record = TransferRecord(
            deviceName = device.name,
            devicePlatform = device.platform,
            direction = TransferDirection.OUTGOING,
            filename = filenames.firstOrNull() ?: "Document",
            fileCount = filenames.size,
            totalSizeBytes = totalBytes,
            progress = 0.05f,
            speedBytesPerSec = 38_500_000.0,
            etaSeconds = 6L,
            status = TransferStatus.TRANSFERRING
        )

        _uiState.update { it.copy(activeTransfer = record) }

        viewModelScope.launch {
            val totalSteps = 10
            for (i in 1..totalSteps) {
                delay(200)
                if (com.nearside.app.transfer.TransferEngine.isTransferCancelled(record.id)) {
                    return@launch
                }
                val frac = i / totalSteps.toFloat()
                val remainingSec = ((totalSteps - i) * 0.25).toLong()
                _uiState.update { current ->
                    current.activeTransfer?.let {
                        current.copy(
                            activeTransfer = it.copy(
                                progress = frac,
                                speedBytesPerSec = 35_000_000.0 + (i * 1_200_000.0),
                                etaSeconds = remainingSec
                            )
                        )
                    } ?: current
                }
            }
            _uiState.update { current ->
                val finished = current.activeTransfer?.copy(
                    progress = 1.0f,
                    speedBytesPerSec = 0.0,
                    etaSeconds = 0L,
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

        if (!trustStore.isEnrolled(device.id)) {
            pairDiscoveredDevice(device)
        }

        val record = TransferRecord(
            deviceName = device.name,
            devicePlatform = device.platform,
            direction = TransferDirection.OUTGOING,
            filename = displayFilename,
            fileCount = 1,
            totalSizeBytes = text.toByteArray(Charsets.UTF_8).size.toLong(),
            progress = 0.05f,
            speedBytesPerSec = 0.0,
            etaSeconds = null,
            status = TransferStatus.TRANSFERRING,
            payloadType = if (isUrl) PayloadType.URL else PayloadType.TEXT,
            payloadText = text
        )
        _uiState.update { it.copy(activeTransfer = record) }

        val resolved = if (device.ipAddress.isNullOrEmpty()) {
            val disc = com.nearside.app.discovery.NsdDiscoveryService.findDiscoveredDevice(device.id)
                ?: com.nearside.app.discovery.NsdDiscoveryService.findDiscoveredDevice(device.fingerprint)
                ?: _uiState.value.discoveredDevices.firstOrNull { it.id == device.id || it.fingerprint == device.fingerprint }
                ?: _uiState.value.discoveredDevices.firstOrNull()
            if (disc != null && !disc.ipAddress.isNullOrEmpty()) {
                device.copy(ipAddress = disc.ipAddress, port = disc.port)
            } else device
        } else device

        val host = resolved.ipAddress ?: "127.0.0.1"
        viewModelScope.launch {
            val res = com.nearside.app.transfer.TransferEngine.sendText(
                text = text,
                isUrl = isUrl,
                host = host,
                port = resolved.port ?: 41433,
                senderId = deviceIdentity.publicIdentity,
                onProgress = { frac, _, _ -> },
                onProgressMetrics = { frac, bytesSent, total, speed, eta ->
                    _uiState.update { current ->
                        current.activeTransfer?.let {
                            current.copy(
                                activeTransfer = it.copy(
                                    progress = frac,
                                    speedBytesPerSec = speed,
                                    etaSeconds = eta
                                )
                            )
                        } ?: current
                    }
                }
            )

            _uiState.update { current ->
                val failureException = res.exceptionOrNull()
                val nearsideErr = failureException as? com.nearside.app.diagnostics.NearsideError
                val isCancelled = com.nearside.app.transfer.TransferEngine.isTransferCancelled(record.id)
                val status = when {
                    isCancelled -> TransferStatus.CANCELLED
                    res.isSuccess -> TransferStatus.COMPLETED
                    else -> TransferStatus.FAILED
                }
                val errorCode = nearsideErr?.code?.code ?: (if (res.isSuccess) null else com.nearside.app.diagnostics.NearsideErrorCode.TRANSFER_INTERRUPTED.code)
                val errorMessage = failureException?.message

                val finished = current.activeTransfer?.copy(
                    progress = 1.0f,
                    speedBytesPerSec = 0.0,
                    etaSeconds = 0L,
                    status = status,
                    errorCode = errorCode,
                    errorMessage = errorMessage,
                    correlationId = current.activeTransfer.id
                )
                val updatedHistory = if (finished != null) {
                    listOf(finished) + current.recentTransfers
                } else current.recentTransfers

                current.copy(
                    activeTransfer = null,
                    recentTransfers = updatedHistory,
                    toastMessage = if (res.isSuccess) "Clipboard sent to ${device.name}" else "Failed to send clipboard: ${errorMessage ?: "Transfer error"}"
                )
            }
            delay(2000)
            _uiState.update { it.copy(toastMessage = null) }
        }
    }

    override fun onCleared() {
        super.onCleared()
        nsdDiscovery.release()
    }
}
