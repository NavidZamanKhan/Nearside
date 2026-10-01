package com.nearside.app.ui

import android.Manifest
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
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
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.QrCode
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Smartphone
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.nearside.app.model.DevicePlatform
import com.nearside.app.model.NearsideDevice
import com.nearside.app.model.TransferDirection
import com.nearside.app.model.TransferRecord
import com.nearside.app.service.NearsideReceiverService
import com.nearside.app.state.AppViewModel
import com.nearside.app.state.NearsideUiState
import com.nearside.app.ui.theme.NearsideAmber
import com.nearside.app.ui.theme.NearsideBlue
import com.nearside.app.ui.theme.NearsideGreen
import com.nearside.app.ui.theme.NearsideTheme

class MainActivity : ComponentActivity() {

    private val viewModel: AppViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Request notification permission on Android 13+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED
            ) {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 101)
            }
        }

        // Start resident background receiving service
        NearsideReceiverService.start(this)

        setContent {
            NearsideTheme {
                val uiState by viewModel.uiState.collectAsState()
                MainScreen(
                    uiState = uiState,
                    onToggleReceiving = { viewModel.toggleReceiving(this) },
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
                    onClearHistory = { viewModel.clearHistory() }
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(
    uiState: NearsideUiState,
    onToggleReceiving: () -> Unit,
    onUnpair: (String) -> Unit,
    onPairWithCode: (String) -> Unit,
    onPairWithQrUri: (String) -> Boolean,
    onSendFiles: (NearsideDevice, List<Uri>) -> Unit,
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
                    ReceivingStatusBadge(
                        isActive = uiState.isReceivingActive,
                        onClick = onToggleReceiving
                    )
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

            // Active Transfer Section (if any)
            uiState.activeTransfer?.let { transfer ->
                item {
                    ActiveTransferCard(transfer = transfer)
                }
            }

            // Local Identity Card
            item {
                IdentityCard(
                    uiState = uiState,
                    onShowQr = { showQrDialog = true },
                    onEnterCode = { showCodeDialog = true }
                )
            }

            // Discovered / Paired Peers Section
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
                        onSendClick = {
                            targetDeviceForPicker = device
                            filePickerLauncher.launch("*/*")
                        },
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
fun ReceivingStatusBadge(isActive: Boolean, onClick: () -> Unit) {
    Surface(
        modifier = Modifier
            .padding(end = 12.dp)
            .clip(RoundedCornerShape(16.dp))
            .clickable(onClick = onClick),
        color = if (isActive) NearsideGreen.copy(alpha = 0.15f) else NearsideAmber.copy(alpha = 0.15f)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Icon(
                imageVector = if (isActive) Icons.Default.PlayArrow else Icons.Default.Pause,
                contentDescription = null,
                tint = if (isActive) NearsideGreen else NearsideAmber,
                modifier = Modifier.size(14.dp)
            )
            Text(
                text = if (isActive) "Receiving" else "Paused",
                color = if (isActive) NearsideGreen else NearsideAmber,
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium
            )
        }
    }
}

@Composable
fun ActiveTransferCard(transfer: TransferRecord) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)
    ) {
        Column(modifier = Modifier.padding(14.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "Sending to ${transfer.deviceName}...",
                    style = MaterialTheme.typography.titleMedium
                )
                Text(
                    text = "${(transfer.progress * 100).toInt()}%",
                    fontFamily = FontFamily.Monospace,
                    fontSize = 12.sp,
                    color = NearsideBlue
                )
            }
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = transfer.filename,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.height(8.dp))
            LinearProgressIndicator(
                progress = { transfer.progress },
                modifier = Modifier.fillMaxWidth()
            )
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
            Text(
                text = "IP: ${uiState.localIpAddress}:${uiState.localPort}",
                fontFamily = FontFamily.Monospace,
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            Spacer(modifier = Modifier.height(14.dp))

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(
                    onClick = onShowQr,
                    modifier = Modifier.weight(1f)
                ) {
                    Icon(Icons.Default.QrCode, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(text = "Show QR", fontSize = 12.sp)
                }

                Button(
                    onClick = onEnterCode,
                    modifier = Modifier.weight(1f),
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
    onSendClick: () -> Unit,
    onUnpairClick: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(14.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .background(NearsideBlue.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = if (device.platform == DevicePlatform.MACOS) Icons.Default.Computer else Icons.Default.Smartphone,
                    contentDescription = null,
                    tint = NearsideBlue,
                    modifier = Modifier.size(20.dp)
                )
            }

            Spacer(modifier = Modifier.width(12.dp))

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = device.name,
                    style = MaterialTheme.typography.titleMedium
                )
                Text(
                    text = "${device.platform.displayName} • ${device.shortFingerprint}",
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            Button(
                onClick = onSendClick,
                colors = ButtonDefaults.buttonColors(containerColor = NearsideBlue)
            ) {
                Icon(Icons.AutoMirrored.Filled.Send, contentDescription = null, modifier = Modifier.size(14.dp))
                Spacer(modifier = Modifier.width(4.dp))
                Text(text = "Send", fontSize = 12.sp)
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
        Box(
            modifier = Modifier
                .size(32.dp)
                .clip(CircleShape)
                .background(if (isIncoming) NearsideGreen.copy(alpha = 0.15f) else NearsideBlue.copy(alpha = 0.15f)),
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
