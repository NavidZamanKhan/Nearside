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
import com.nearside.app.discovery.deduplicateDevicesByIdentity
import com.nearside.app.model.DevicePlatform
import com.nearside.app.model.DeviceReachability
import com.nearside.app.model.NearsideDevice
import com.nearside.app.model.PayloadType
import com.nearside.app.model.TransferDirection
import com.nearside.app.model.TransferRecord
import com.nearside.app.model.TransferStatus
import com.nearside.app.service.NearsideReceiverService
import com.nearside.app.transfer.TransferEngine
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
    val trustStore: PinnedTrustStore = PinnedTrustStore.fromContext(context)
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
        viewModelScope.launch {
            trustStore.changes.collect { loadEnrolledAndSeedData() }
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
            val paired = NearsideDevice(
                id = record.identity,
                name = record.name,
                platform = platform,
                fingerprint = record.identity,
                ipAddress = record.lastKnownIp,
                port = record.lastKnownPort,
                reachability = DeviceReachability.ONLINE
            )
            NsdDiscoveryService.findDiscoveredDevice(record.identity)?.let { live ->
                paired.copy(ipAddress = live.ipAddress, port = live.port, reachability = live.reachability)
            } ?: paired
        }

        _uiState.update {
            it.copy(
                pairedDevices = pairedList
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
                val peers = deduplicateDevicesByIdentity(discovered)
                _uiState.update { current ->
                    val updatedPaired = current.pairedDevices.map { paired ->
                        val match = peers.find { it.id == paired.id || it.fingerprint == paired.fingerprint }
                        if (match != null && match.ipAddress != null) {
                            paired.copy(
                                ipAddress = match.ipAddress,
                                port = match.port,
                                reachability = match.reachability
                            )
                        } else paired.copy(reachability = DeviceReachability.UNREACHABLE)
                    }
                    current.copy(discoveredDevices = peers, pairedDevices = updatedPaired)
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
        val payload = QRPairingPayload.fromUri(uriString) ?: run {
            com.nearside.app.diagnostics.NearsideLogger.warn("pairing", "parseQR", "Malformed pairing URI", state = "rejected", errorCode = com.nearside.app.diagnostics.NearsideErrorCode.PAIRING_MALFORMED_PAYLOAD)
            _uiState.update { it.copy(toastMessage = "Invalid Nearside pairing QR code") }
            return false
        }
        if (payload.isExpired) {
            com.nearside.app.diagnostics.NearsideLogger.warn("pairing", "parseQR", "Pairing session expired", state = "rejected", correlationId = payload.sessionId, errorCode = com.nearside.app.diagnostics.NearsideErrorCode.PAIRING_SESSION_EXPIRED)
            _uiState.update { it.copy(toastMessage = "Pairing QR expired. Display a fresh code.") }
            return false
        }
        val livePeer = _uiState.value.discoveredDevices.firstOrNull { it.id == payload.hostIdentity && it.fingerprint == payload.hostIdentity }
        val host = livePeer?.ipAddress ?: payload.ip
        val port = livePeer?.port ?: payload.port ?: 41433
        if (!host.isNullOrEmpty()) {
            viewModelScope.launch {
                val res = TransferEngine.initiatePairing(host = host, port = port, confirmationCode = "", trustStore = trustStore, qrPayload = payload, deviceIdentity = deviceIdentity)
                res.onSuccess { resp ->
                    val newDevice = NearsideDevice(
                        id = resp.serverId,
                        name = resp.serverName,
                        platform = DevicePlatform.MACOS,
                        fingerprint = resp.serverId,
                        ipAddress = host,
                        port = port,
                        reachability = DeviceReachability.ONLINE
                    )
                    _uiState.update { current ->
                        current.copy(pairedDevices = current.pairedDevices.filterNot { it.id == resp.serverId } + newDevice)
                    }
                }.onFailure { error ->
                    _uiState.update { it.copy(toastMessage = error.message ?: "Pairing failed. Display a fresh QR and try again.") }
                }
            }
            return true
        }
        return false
    }

    fun pairWithHost(host: String, port: Int = 41433) {
        _uiState.update { it.copy(toastMessage = "To securely pair, scan or paste the other device’s current Nearside QR code.") }
    }

    fun pairDiscoveredDevice(device: NearsideDevice) {
        _uiState.update { it.copy(toastMessage = "Display a pairing QR on ${device.name}, then select Scan QR.") }
    }

    fun pairWithCode(code: String) {
        _uiState.update { it.copy(toastMessage = "Short-code network verification is unavailable. Scan or paste a current pairing QR code.") }
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

        val resolved = NsdDiscoveryService.findDiscoveredDevice(device.fingerprint) ?: device
        val host = resolved.ipAddress.orEmpty()
        viewModelScope.launch {
            val res = com.nearside.app.transfer.TransferEngine.sendFiles(
                files = files,
                host = host,
                port = resolved.port ?: 41433,
                senderId = deviceIdentity.publicIdentity,
                peerIdentity = device.fingerprint,
                trustStore = trustStore,
                deviceIdentity = deviceIdentity,
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

        val resolved = NsdDiscoveryService.findDiscoveredDevice(device.fingerprint) ?: device
        val host = resolved.ipAddress.orEmpty()
        viewModelScope.launch {
            val res = com.nearside.app.transfer.TransferEngine.sendText(
                text = text,
                isUrl = isUrl,
                host = host,
                port = resolved.port ?: 41433,
                senderId = deviceIdentity.publicIdentity,
                peerIdentity = device.fingerprint,
                trustStore = trustStore,
                deviceIdentity = deviceIdentity,
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
