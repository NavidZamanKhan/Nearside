package com.nearside.app.state

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nearside.app.model.DevicePlatform
import com.nearside.app.model.DeviceReachability
import com.nearside.app.model.NearsideDevice
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
    val activeTransfer: TransferRecord? = null
)

class AppViewModel : ViewModel() {

    private val _uiState = MutableStateFlow(NearsideUiState())
    val uiState: StateFlow<NearsideUiState> = _uiState.asStateFlow()

    init {
        loadInitialState()
    }

    private fun loadInitialState() {
        val initialPaired = listOf(
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

        val initialDiscovered = listOf(
            NearsideDevice(
                id = "dev_macbook_pro",
                name = "MacBook Pro",
                platform = DevicePlatform.MACOS,
                fingerprint = "ns1_39a8bc43d87e51240a1b9f4277cd01ab",
                ipAddress = "192.168.0.104",
                port = 41433,
                reachability = DeviceReachability.ONLINE
            )
        )

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
                pairedDevices = initialPaired,
                discoveredDevices = initialDiscovered,
                recentTransfers = initialTransfers
            )
        }
    }

    fun toggleReceiving(context: Context) {
        val newState = !_uiState.value.isReceivingActive
        _uiState.update { it.copy(isReceivingActive = newState) }
        if (newState) {
            NearsideReceiverService.resume(context)
        } else {
            NearsideReceiverService.pause(context)
        }
    }

    fun unpairDevice(deviceId: String) {
        _uiState.update { current ->
            current.copy(pairedDevices = current.pairedDevices.filterNot { it.id == deviceId })
        }
    }

    fun pairWithCode(code: String) {
        if (code.length >= 6) {
            val newDevice = NearsideDevice(
                name = "Paired Peer (${code.take(4)})",
                platform = DevicePlatform.MACOS,
                fingerprint = "ns1_peer_$code"
            )
            _uiState.update { current ->
                current.copy(pairedDevices = current.pairedDevices + newDevice)
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
}
