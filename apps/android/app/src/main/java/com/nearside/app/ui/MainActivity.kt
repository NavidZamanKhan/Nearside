package com.nearside.app.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.PowerSettingsNew
import androidx.compose.material.icons.filled.QrCode
import androidx.compose.material.icons.filled.Smartphone
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.WifiTethering
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.nearside.app.model.DevicePlatform
import com.nearside.app.model.NearsideDevice
import com.nearside.app.model.PayloadType
import com.nearside.app.model.TransferDirection
import com.nearside.app.model.TransferRecord
import com.nearside.app.model.TransferStatus
import com.nearside.app.service.NearsideReceiverService
import com.nearside.app.state.AppViewModel
import com.nearside.app.state.NearsideUiState
import com.nearside.app.ui.theme.NearsideAmber
import com.nearside.app.ui.theme.NearsideBlue
import com.nearside.app.ui.theme.NearsideGreen
import com.nearside.app.ui.theme.NearsideTheme

class MainActivity : ComponentActivity() {

    private val viewModel: AppViewModel by viewModels()
    private var isBatteryExempt by mutableStateOf(true)

    private val notificationPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { isGranted ->
        if (isGranted) {
            NearsideReceiverService.refresh(this)
        }
    }

    private fun checkBatteryOptimizationStatus() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
            isBatteryExempt = powerManager?.isIgnoringBatteryOptimizations(packageName) == true
        } else {
            isBatteryExempt = true
        }
    }

    private fun requestBatteryExemption() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = Uri.parse("package:$packageName")
                }
                startActivity(intent)
            } catch (e: Exception) {
                val fallbackIntent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                startActivity(fallbackIntent)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        checkBatteryOptimizationStatus()

        // Request notification permission on Android 13+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED
            ) {
                notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
        }

        // Start resident background receiving service
        NearsideReceiverService.start(this)

        setContent {
            NearsideTheme {
                val uiState by viewModel.uiState.collectAsState()
                MainScreen(
                    uiState = uiState,
                    isBatteryExempt = isBatteryExempt,
                    onRequestBatteryExemption = { requestBatteryExemption() },
                    onToggleReceiving = { viewModel.toggleReceiving(this) },
                    onCancelTransfer = { viewModel.cancelTransfer(it) },
                    onUnpair = { viewModel.unpairDevice(it) },
                    onPairWithCode = { viewModel.pairWithCode(it) },
                    onPairWithQrUri = { viewModel.pairWithQrUri(it) },
                    onSendFiles = { device, uris ->
                        val staged = uris.mapNotNull { uri ->
                            try {
                                val name = uri.lastPathSegment?.substringAfterLast('/') ?: "file_${System.currentTimeMillis()}"
                                val temp = java.io.File(cacheDir, name)
                                contentResolver.openInputStream(uri)?.use { input ->
                                    java.io.FileOutputStream(temp).use { output ->
                                        input.copyTo(output)
                                    }
                                }
                                temp
                            } catch (e: Exception) {
                                null
                            }
                        }
                        if (staged.isNotEmpty()) {
                            viewModel.sendFiles(staged, device)
                        } else {
                            val filenames = uris.map { it.lastPathSegment ?: "file" }
                            viewModel.simulateTransfer(device, filenames, 25_000_000L)
                        }
                    },
                    onBeamClipboard = { viewModel.sendClipboard(it) },
                    onClearHistory = { viewModel.clearHistory() }
                )
            }
        }
    }

    override fun onResume() {
        super.onResume()
        checkBatteryOptimizationStatus()
        NearsideReceiverService.refresh(this)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(
    uiState: NearsideUiState,
    isBatteryExempt: Boolean = true,
    onRequestBatteryExemption: () -> Unit = {},
    onToggleReceiving: () -> Unit,
    onCancelTransfer: (String) -> Unit,
    onUnpair: (String) -> Unit,
    onPairWithCode: (String) -> Unit,
    onPairWithQrUri: (String) -> Boolean,
    onSendFiles: (NearsideDevice, List<Uri>) -> Unit,
    onBeamClipboard: (NearsideDevice) -> Unit,
    onClearHistory: () -> Unit
) {
    var showQrDialog by remember { mutableStateOf(false) }
    var showCodeDialog by remember { mutableStateOf(false) }
    var targetDeviceForPicker by remember { mutableStateOf<NearsideDevice?>(null) }

    val filePickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.GetMultipleContents()
    ) { uris ->
        if (uris.isNotEmpty() && targetDeviceForPicker != null) {
            onSendFiles(targetDeviceForPicker!!, uris)
            targetDeviceForPicker = null
        }
    }

    val photoPickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickMultipleVisualMedia()
    ) { uris ->
        if (uris.isNotEmpty() && targetDeviceForPicker != null) {
            onSendFiles(targetDeviceForPicker!!, uris)
            targetDeviceForPicker = null
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = "Nearside",
                            fontWeight = FontWeight.Bold,
                            fontSize = 20.sp
                        )
                        Spacer(modifier = Modifier.width(8.dp))
                        Box(
                            modifier = Modifier
                                .size(8.dp)
                                .clip(CircleShape)
                                .background(if (uiState.isReceivingActive) NearsideGreen else NearsideAmber)
                        )
                    }
                },
                actions = {
                    Surface(
                        shape = RoundedCornerShape(12.dp),
                        color = MaterialTheme.colorScheme.surfaceVariant,
                        modifier = Modifier.padding(end = 12.dp)
                    ) {
                        Text(
                            text = "${uiState.localIpAddress}:${uiState.localPort}",
                            fontFamily = FontFamily.Monospace,
                            fontSize = 11.sp,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surface
                )
            )
        }
    ) { paddingValues ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            item { Spacer(modifier = Modifier.height(4.dp)) }

            // Feedback / Toast Banner
            uiState.toastMessage?.let { toast ->
                item {
                    Card(
                        modifier = Modifier.fillMaxWidth(),
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)
                    ) {
                        Row(
                            modifier = Modifier.padding(12.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Icon(Icons.Default.ContentPaste, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(text = toast, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onPrimaryContainer)
                        }
                    }
                }
            }

            // Background Persistence Card (shown when battery optimizations are active)
            if (!isBatteryExempt) {
                item {
                    Card(
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(16.dp),
                        colors = CardDefaults.cardColors(
                            containerColor = MaterialTheme.colorScheme.surfaceVariant
                        )
                    ) {
                        Column(modifier = Modifier.padding(16.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(
                                    imageVector = Icons.Default.PowerSettingsNew,
                                    contentDescription = null,
                                    tint = NearsideAmber,
                                    modifier = Modifier.size(24.dp)
                                )
                                Spacer(modifier = Modifier.width(12.dp))
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = "Keep Resident in Background",
                                        style = MaterialTheme.typography.titleSmall,
                                        fontWeight = FontWeight.SemiBold
                                    )
                                    Text(
                                        text = "Allow background power consumption so the notification banner stays active when the app is closed.",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                            }
                            Spacer(modifier = Modifier.height(12.dp))
                            Button(
                                onClick = onRequestBatteryExemption,
                                modifier = Modifier.fillMaxWidth(),
                                shape = RoundedCornerShape(10.dp)
                            ) {
                                Text("Allow Background Running")
                            }
                        }
                    }
                }
            }

            // Hero Control Center Receiving Mode Card
            item {
                ControlCenterHeroCard(
                    isReceivingActive = uiState.isReceivingActive,
                    onToggle = onToggleReceiving
                )
            }

            // In-flight Velocity Tracker Card
            uiState.activeTransfer?.let { transfer ->
                item {
                    ActiveTransferCard(
                        transfer = transfer,
                        onCancel = { onCancelTransfer(transfer.id) }
                    )
                }
            }

            // Direct Media Dispatch Bar
            item {
                DirectActionsRow(
                    onPickFiles = {
                        targetDeviceForPicker = uiState.pairedDevices.firstOrNull()
                        filePickerLauncher.launch("*/*")
                    },
                    onPickPhotos = {
                        targetDeviceForPicker = uiState.pairedDevices.firstOrNull()
                        photoPickerLauncher.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
                    },
                    onShowPairing = { showQrDialog = true }
                )
            }

            // Local Identity Card
            item {
                IdentityCard(
                    uiState = uiState,
                    onShowQr = { showQrDialog = true },
                    onEnterCode = { showCodeDialog = true }
                )
            }

            // Available Peers Section
            item {
                Text(
                    text = "AVAILABLE PEERS",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontWeight = FontWeight.Bold
                )
            }

            if (uiState.pairedDevices.isEmpty()) {
                item {
                    Card(
                        modifier = Modifier.fillMaxWidth(),
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(24.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            Text(
                                text = "No paired peers. Use QR or short code to pair.",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }
            } else {
                items(uiState.pairedDevices, key = { it.id }) { device ->
                    DeviceRowCard(
                        device = device,
                        onSendFilesClick = {
                            targetDeviceForPicker = device
                            filePickerLauncher.launch("*/*")
                        },
                        onSendPhotosClick = {
                            targetDeviceForPicker = device
                            photoPickerLauncher.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
                        },
                        onBeamClipboard = { onBeamClipboard(device) },
                        onUnpairClick = { onUnpair(device.id) }
                    )
                }
            }

            // Transfer History Section
            item {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = "RECENT TRANSFERS",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontWeight = FontWeight.Bold
                    )
                    if (uiState.recentTransfers.isNotEmpty()) {
                        TextButton(onClick = onClearHistory) {
                            Text(text = "Clear", fontSize = 12.sp)
                        }
                    }
                }
            }

            if (uiState.recentTransfers.isEmpty()) {
                item {
                    Text(
                        text = "No transfers yet.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(vertical = 12.dp)
                    )
                }
            } else {
                items(uiState.recentTransfers, key = { it.id }) { record ->
                    TransferRow(record = record)
                }
            }

            item { Spacer(modifier = Modifier.height(24.dp)) }
        }
    }

    if (showQrDialog) {
        QrPairingDialog(
            fingerprint = uiState.localFingerprint,
            onDismiss = { showQrDialog = false },
            onPairWithUri = { uri ->
                val ok = onPairWithQrUri(uri)
                if (ok) showQrDialog = false
            }
        )
    }

    if (showCodeDialog) {
        ShortCodePairingDialog(
            localCode = uiState.activePairingCode,
            onDismiss = { showCodeDialog = false },
            onConfirmCode = { code ->
                onPairWithCode(code)
                showCodeDialog = false
            }
        )
    }
}

@Composable
fun ControlCenterHeroCard(
    isReceivingActive: Boolean,
    onToggle: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(
            containerColor = if (isReceivingActive)
                NearsideGreen.copy(alpha = 0.10f)
            else
                MaterialTheme.colorScheme.surfaceVariant
        )
    ) {
        Column(modifier = Modifier.padding(18.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        modifier = Modifier
                            .size(44.dp)
                            .clip(CircleShape)
                            .background(
                                if (isReceivingActive)
                                    NearsideGreen.copy(alpha = 0.20f)
                                else
                                    MaterialTheme.colorScheme.outline.copy(alpha = 0.20f)
                            ),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            imageVector = if (isReceivingActive) Icons.Default.WifiTethering else Icons.Default.PowerSettingsNew,
                            contentDescription = null,
                            tint = if (isReceivingActive) NearsideGreen else MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(24.dp)
                        )
                    }

                    Spacer(modifier = Modifier.width(14.dp))

                    Column {
                        Text(
                            text = if (isReceivingActive) "Receiving Ready" else "Dormant (Off)",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold
                        )
                        Text(
                            text = if (isReceivingActive) "Port 41433 • Broadcasting mDNS" else "Zero battery • Sockets closed",
                            fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }

                Switch(
                    checked = isReceivingActive,
                    onCheckedChange = { onToggle() },
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = Color.White,
                        checkedTrackColor = NearsideGreen
                    )
                )
            }

            Spacer(modifier = Modifier.height(12.dp))

            Text(
                text = if (isReceivingActive)
                    "Nearside is receptive to inbound files and clipboard beaming from trusted peers on this network."
                else
                    "Receiving is turned off to save battery and memory. Outbound sending remains available anytime.",
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
fun DirectActionsRow(
    onPickFiles: () -> Unit,
    onPickPhotos: () -> Unit,
    onShowPairing: () -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        OutlinedButton(
            onClick = onPickFiles,
            modifier = Modifier.weight(1f),
            shape = RoundedCornerShape(12.dp)
        ) {
            Icon(Icons.Default.Folder, contentDescription = null, modifier = Modifier.size(16.dp))
            Spacer(modifier = Modifier.width(6.dp))
            Text(text = "Files", fontSize = 12.sp)
        }

        OutlinedButton(
            onClick = onPickPhotos,
            modifier = Modifier.weight(1f),
            shape = RoundedCornerShape(12.dp)
        ) {
            Icon(Icons.Default.Image, contentDescription = null, modifier = Modifier.size(16.dp))
            Spacer(modifier = Modifier.width(6.dp))
            Text(text = "Photos", fontSize = 12.sp)
        }

        Button(
            onClick = onShowPairing,
            modifier = Modifier.weight(1f),
            shape = RoundedCornerShape(12.dp),
            colors = ButtonDefaults.buttonColors(containerColor = NearsideBlue)
        ) {
            Icon(Icons.Default.QrCode, contentDescription = null, modifier = Modifier.size(16.dp))
            Spacer(modifier = Modifier.width(6.dp))
            Text(text = "Pair", fontSize = 12.sp)
        }
    }
}

@Composable
fun ActiveTransferCard(
    transfer: TransferRecord,
    onCancel: () -> Unit
) {
    val isIncoming = transfer.direction == TransferDirection.INCOMING
    val speedText = transfer.formattedSpeed
    val etaText = transfer.formattedEta

    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        modifier = Modifier
                            .size(32.dp)
                            .clip(CircleShape)
                            .background(if (isIncoming) NearsideGreen.copy(alpha = 0.2f) else NearsideBlue.copy(alpha = 0.2f)),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            imageVector = if (isIncoming) Icons.AutoMirrored.Filled.ArrowBack else Icons.AutoMirrored.Filled.ArrowForward,
                            contentDescription = null,
                            tint = if (isIncoming) NearsideGreen else NearsideBlue,
                            modifier = Modifier.size(16.dp)
                        )
                    }
                    Spacer(modifier = Modifier.width(10.dp))
                    Column {
                        Text(
                            text = if (isIncoming) "Receiving from ${transfer.deviceName}..." else "Sending to ${transfer.deviceName}...",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold
                        )
                        Text(
                            text = "${transfer.filename} (${transfer.formattedSize})",
                            fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }

                Text(
                    text = "${(transfer.progress * 100).toInt()}%",
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Bold,
                    fontSize = 14.sp,
                    color = NearsideBlue
                )
            }

            Spacer(modifier = Modifier.height(12.dp))

            LinearProgressIndicator(
                progress = { transfer.progress },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(8.dp)
                    .clip(RoundedCornerShape(4.dp))
            )

            Spacer(modifier = Modifier.height(10.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (speedText.isNotEmpty()) {
                        Icon(Icons.Default.Speed, contentDescription = null, modifier = Modifier.size(14.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        Spacer(modifier = Modifier.width(4.dp))
                        Text(text = speedText, fontSize = 11.sp, fontFamily = FontFamily.Monospace, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Spacer(modifier = Modifier.width(12.dp))
                    }
                    if (etaText.isNotEmpty()) {
                        Icon(Icons.Default.Timer, contentDescription = null, modifier = Modifier.size(14.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        Spacer(modifier = Modifier.width(4.dp))
                        Text(text = etaText, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }

                OutlinedButton(
                    onClick = onCancel,
                    shape = RoundedCornerShape(8.dp),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error)
                ) {
                    Icon(Icons.Default.Close, contentDescription = null, modifier = Modifier.size(12.dp))
                    Spacer(modifier = Modifier.width(4.dp))
                    Text(text = "Cancel", fontSize = 11.sp)
                }
            }
        }
    }
}

@Composable
fun IdentityCard(
    uiState: NearsideUiState,
    onShowQr: () -> Unit,
    onEnterCode: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text(
                text = "Device Identity",
                style = MaterialTheme.typography.titleMedium
            )
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = uiState.localDeviceName,
                fontWeight = FontWeight.Bold,
                fontSize = 18.sp
            )
            Text(
                text = "Fingerprint: ${uiState.localFingerprint.take(18)}...",
                fontFamily = FontFamily.Monospace,
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            Spacer(modifier = Modifier.height(14.dp))

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(
                    onClick = onShowQr,
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(10.dp)
                ) {
                    Icon(Icons.Default.QrCode, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(text = "Show QR", fontSize = 12.sp)
                }

                Button(
                    onClick = onEnterCode,
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(10.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = NearsideBlue)
                ) {
                    Text(text = "Pair Code", fontSize = 12.sp)
                }
            }
        }
    }
}

@Composable
fun DeviceRowCard(
    device: NearsideDevice,
    onSendFilesClick: () -> Unit,
    onSendPhotosClick: () -> Unit,
    onBeamClipboard: () -> Unit,
    onUnpairClick: () -> Unit
) {
    val platformColor = when (device.platform) {
        DevicePlatform.MACOS -> NearsideBlue
        DevicePlatform.ANDROID -> NearsideGreen
        DevicePlatform.IOS -> Color(0xFF8B5CF6)
        DevicePlatform.WINDOWS -> Color(0xFF0284C7)
        DevicePlatform.LINUX -> Color(0xFFEA580C)
    }

    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)
    ) {
        Column(modifier = Modifier.padding(14.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    modifier = Modifier
                        .size(42.dp)
                        .clip(CircleShape)
                        .background(platformColor.copy(alpha = 0.15f)),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = if (device.platform == DevicePlatform.MACOS || device.platform == DevicePlatform.WINDOWS || device.platform == DevicePlatform.LINUX)
                            Icons.Default.Computer
                        else
                            Icons.Default.Smartphone,
                        contentDescription = null,
                        tint = platformColor,
                        modifier = Modifier.size(22.dp)
                    )
                }

                Spacer(modifier = Modifier.width(12.dp))

                Column(modifier = Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = device.name,
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold
                        )
                        Spacer(modifier = Modifier.width(6.dp))
                        Surface(
                            shape = RoundedCornerShape(6.dp),
                            color = platformColor.copy(alpha = 0.15f)
                        ) {
                            Text(
                                text = device.platform.displayName,
                                fontSize = 10.sp,
                                fontWeight = FontWeight.Bold,
                                color = platformColor,
                                modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                            )
                        }
                    }
                    Text(
                        text = "${device.shortFingerprint} • ${device.ipAddress ?: "Direct"}",
                        fontSize = 11.sp,
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }

                IconButton(
                    onClick = onUnpairClick,
                    modifier = Modifier.size(32.dp)
                ) {
                    Icon(
                        Icons.Default.DeleteOutline,
                        contentDescription = "Unpair",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(18.dp)
                    )
                }
            }

            Spacer(modifier = Modifier.height(12.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                OutlinedButton(
                    onClick = onSendFilesClick,
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(10.dp)
                ) {
                    Icon(Icons.Default.Folder, contentDescription = null, modifier = Modifier.size(14.dp))
                    Spacer(modifier = Modifier.width(4.dp))
                    Text(text = "Send File", fontSize = 11.sp)
                }

                OutlinedButton(
                    onClick = onSendPhotosClick,
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(10.dp)
                ) {
                    Icon(Icons.Default.Image, contentDescription = null, modifier = Modifier.size(14.dp))
                    Spacer(modifier = Modifier.width(4.dp))
                    Text(text = "Photos", fontSize = 11.sp)
                }

                Button(
                    onClick = onBeamClipboard,
                    shape = RoundedCornerShape(10.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = NearsideBlue)
                ) {
                    Icon(Icons.Default.ContentPaste, contentDescription = null, modifier = Modifier.size(14.dp))
                    Spacer(modifier = Modifier.width(4.dp))
                    Text(text = "Beam", fontSize = 11.sp)
                }
            }
        }
    }
}

@Composable
fun TransferRow(record: TransferRecord) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        val isIncoming = record.direction == TransferDirection.INCOMING
        val isUrl = record.payloadType == PayloadType.URL
        val isText = record.payloadType == PayloadType.TEXT
        val isFailed = record.status == TransferStatus.FAILED
        val isCancelled = record.status == TransferStatus.CANCELLED

        val badgeColor = when {
            isFailed -> MaterialTheme.colorScheme.error
            isCancelled -> NearsideAmber
            isIncoming -> NearsideGreen
            else -> NearsideBlue
        }

        Box(
            modifier = Modifier
                .size(34.dp)
                .clip(CircleShape)
                .background(badgeColor.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center
        ) {
            val iconVector = when {
                isCancelled -> Icons.Default.Close
                isUrl -> Icons.Default.Link
                isText -> Icons.Default.ContentPaste
                isIncoming -> Icons.AutoMirrored.Filled.ArrowBack
                else -> Icons.AutoMirrored.Filled.ArrowForward
            }
            Icon(
                imageVector = iconVector,
                contentDescription = null,
                tint = badgeColor,
                modifier = Modifier.size(16.dp)
            )
        }

        Spacer(modifier = Modifier.width(10.dp))

        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = record.filename,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium
            )
            Text(
                text = "${record.deviceName} • ${record.formattedSize}",
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        if (isCancelled) {
            Surface(
                shape = RoundedCornerShape(6.dp),
                color = NearsideAmber.copy(alpha = 0.15f)
            ) {
                Text(
                    text = "Cancelled",
                    color = NearsideAmber,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                )
            }
        } else if (isFailed) {
            Surface(
                shape = RoundedCornerShape(6.dp),
                color = MaterialTheme.colorScheme.error.copy(alpha = 0.15f)
            ) {
                Text(
                    text = "Failed",
                    color = MaterialTheme.colorScheme.error,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                )
            }
        }
    }
}

@Composable
fun QrPairingDialog(
    fingerprint: String,
    onDismiss: () -> Unit,
    onPairWithUri: (String) -> Unit
) {
    var uriInput by remember { mutableStateOf("") }
    var isEnteringUri by remember { mutableStateOf(false) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(text = if (isEnteringUri) "Connect via URI" else "Pair with QR Code") },
        text = {
            Column(
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                if (isEnteringUri) {
                    Text(
                        text = "Paste or enter the nearside://pair URI from your other device:",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(modifier = Modifier.height(12.dp))
                    OutlinedTextField(
                        value = uriInput,
                        onValueChange = { uriInput = it },
                        label = { Text(text = "nearside://pair?...") },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = false,
                        maxLines = 3
                    )
                } else {
                    Text(
                        text = "Scan this code with the Nearside app on your Mac or other device:",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(modifier = Modifier.height(16.dp))
                    Box(
                        modifier = Modifier
                            .size(160.dp)
                            .clip(RoundedCornerShape(12.dp))
                            .background(Color.White),
                        contentAlignment = Alignment.Center
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Icon(
                                imageVector = Icons.Default.QrCode,
                                contentDescription = null,
                                tint = Color.Black,
                                modifier = Modifier.size(100.dp)
                            )
                            Text(
                                text = "nearside://pair",
                                fontSize = 10.sp,
                                fontFamily = FontFamily.Monospace,
                                color = Color.DarkGray
                            )
                        }
                    }
                    Spacer(modifier = Modifier.height(12.dp))
                    Text(
                        text = "Fingerprint: ${fingerprint.take(16)}...",
                        fontFamily = FontFamily.Monospace,
                        fontSize = 10.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Spacer(modifier = Modifier.height(12.dp))
                TextButton(onClick = { isEnteringUri = !isEnteringUri }) {
                    Text(text = if (isEnteringUri) "Show My QR Code" else "Enter URI Manually")
                }
            }
        },
        confirmButton = {
            if (isEnteringUri) {
                Button(
                    onClick = { onPairWithUri(uriInput) },
                    enabled = uriInput.startsWith("nearside://pair")
                ) {
                    Text(text = "Pair")
                }
            } else {
                Button(onClick = onDismiss) {
                    Text(text = "Done")
                }
            }
        },
        dismissButton = {
            if (isEnteringUri) {
                TextButton(onClick = onDismiss) {
                    Text(text = "Cancel")
                }
            }
        }
    )
}

@Composable
fun ShortCodePairingDialog(
    localCode: String,
    onDismiss: () -> Unit,
    onConfirmCode: (String) -> Unit
) {
    var codeInput by remember { mutableStateOf("") }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(text = "Pair with Short Code") },
        text = {
            Column(modifier = Modifier.fillMaxWidth()) {
                Text(
                    text = "Your Pairing Code:",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(modifier = Modifier.height(4.dp))
                Surface(
                    color = MaterialTheme.colorScheme.surfaceVariant,
                    shape = RoundedCornerShape(8.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Box(
                        modifier = Modifier.padding(vertical = 10.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = localCode,
                            fontSize = 24.sp,
                            fontWeight = FontWeight.Bold,
                            fontFamily = FontFamily.Monospace
                        )
                    }
                }

                Spacer(modifier = Modifier.height(16.dp))
                Text(
                    text = "Or enter the 8-digit code from peer device:",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(modifier = Modifier.height(8.dp))
                OutlinedTextField(
                    value = codeInput,
                    onValueChange = { if (it.length <= 8) codeInput = it },
                    label = { Text(text = "8-Digit Code") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true
                )
            }
        },
        confirmButton = {
            Button(
                onClick = { onConfirmCode(codeInput) },
                enabled = codeInput.length >= 6
            ) {
                Text(text = "Confirm")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(text = "Cancel")
            }
        }
    )
}
