package com.nearside.app.ui

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.lifecycle.lifecycleScope
import com.nearside.app.crypto.DeviceIdentity
import com.nearside.app.discovery.NsdDiscoveryService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Smartphone
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nearside.app.crypto.PinnedTrustStore
import com.nearside.app.model.DevicePlatform
import com.nearside.app.model.NearsideDevice
import com.nearside.app.ui.theme.NearsideBlue
import com.nearside.app.ui.theme.NearsideTheme
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class ShareTargetActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val sharedSummary = parseIncomingShareIntent(intent)

        val trustStore = PinnedTrustStore.fromContext(this)
        val knownDevices = trustStore.allEnrolledPeers().map { record ->
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
                ipAddress = record.lastKnownIp ?: "",
                port = record.lastKnownPort ?: 41433
            )
        }

        setContent {
            NearsideTheme {
                SharePickerSheet(
                    summaryText = sharedSummary,
                    devices = knownDevices,
                    onDeviceSelected = { device ->
                        performSend(device)
                    },
                    onDismiss = { finish() }
                )
            }
        }
    }

    private fun performSend(device: NearsideDevice) {
        val shareIntent = intent ?: run { finish(); return }
        val trustStore = PinnedTrustStore.fromContext(this)
        val deviceIdentity = DeviceIdentity.loadOrCreateDefault(this)
        val resolved = NsdDiscoveryService.findDiscoveredDevice(device.fingerprint) ?: device
        val host = resolved.ipAddress.orEmpty()
        val port = resolved.port ?: 41433

        lifecycleScope.launch(Dispatchers.IO) {
            val uris = when (shareIntent.action) {
                Intent.ACTION_SEND -> listOfNotNull(
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        shareIntent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        shareIntent.getParcelableExtra(Intent.EXTRA_STREAM)
                    }
                )
                Intent.ACTION_SEND_MULTIPLE -> (
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        shareIntent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        shareIntent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                    }
                ).orEmpty()
                else -> emptyList()
            }

            val text = shareIntent.getStringExtra(Intent.EXTRA_TEXT)

            if (uris.isNotEmpty()) {
                val staged = uris.mapNotNull { uri ->
                    try {
                        var fileName: String? = null
                        if (uri.scheme == "content") {
                            try {
                                contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                                    if (cursor.moveToFirst()) {
                                        val idx = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                                        if (idx != -1) fileName = cursor.getString(idx)
                                    }
                                }
                            } catch (_: Exception) {}
                        }
                        val safeName = fileName?.takeIf { it.isNotBlank() }
                            ?: uri.lastPathSegment?.substringAfterLast('/')?.takeIf { it.isNotBlank() }
                            ?: "file_${System.currentTimeMillis()}"
                        val cleanName = safeName.replace(Regex("[^a-zA-Z0-9._-]"), "_")
                        val temp = java.io.File(cacheDir, cleanName)
                        contentResolver.openInputStream(uri)?.use { input ->
                            java.io.FileOutputStream(temp).use { output -> input.copyTo(output) }
                        }
                        temp
                    } catch (e: Exception) { null }
                }

                if (staged.isNotEmpty()) {
                    val result = com.nearside.app.transfer.TransferEngine.sendFiles(
                        files = staged,
                        host = host,
                        port = port,
                        senderId = deviceIdentity.publicIdentity,
                        peerIdentity = device.fingerprint,
                        trustStore = trustStore,
                        deviceIdentity = deviceIdentity,
                        onProgress = { _, _, _ -> }
                    )
                    withContext(Dispatchers.Main) {
                        if (result.isSuccess) {
                            Toast.makeText(this@ShareTargetActivity, "Sent to ${device.name}", Toast.LENGTH_SHORT).show()
                        } else {
                            Toast.makeText(this@ShareTargetActivity, "Transfer failed: ${result.exceptionOrNull()?.message}", Toast.LENGTH_LONG).show()
                        }
                        finish()
                    }
                    return@launch
                }
            } else if (!text.isNullOrBlank()) {
                val isUrl = text.startsWith("http://") || text.startsWith("https://")
                val result = com.nearside.app.transfer.TransferEngine.sendText(
                    text = text,
                    isUrl = isUrl,
                    host = host,
                    port = port,
                    senderId = deviceIdentity.publicIdentity,
                    peerIdentity = device.fingerprint,
                    trustStore = trustStore,
                    deviceIdentity = deviceIdentity,
                    onProgress = { _, _, _ -> }
                )
                withContext(Dispatchers.Main) {
                    if (result.isSuccess) {
                        Toast.makeText(this@ShareTargetActivity, "Sent to ${device.name}", Toast.LENGTH_SHORT).show()
                    } else {
                        Toast.makeText(this@ShareTargetActivity, "Transfer failed: ${result.exceptionOrNull()?.message}", Toast.LENGTH_LONG).show()
                    }
                    finish()
                }
                return@launch
            }
            withContext(Dispatchers.Main) {
                Toast.makeText(this@ShareTargetActivity, "No shareable content found", Toast.LENGTH_SHORT).show()
                finish()
            }
        }
    }

    private fun parseIncomingShareIntent(intent: Intent): String {
        return when (intent.action) {
            Intent.ACTION_SEND -> {
                val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)

                when {
                    uri != null -> "1 item ready to share"
                    text != null -> "Text snippet ready to share"
                    else -> "Content ready to share"
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val uris = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                }
                val count = uris?.size ?: 0
                "$count items ready to share"
            }
            else -> "Ready to share"
        }
    }
}

@Composable
fun SharePickerSheet(
    summaryText: String,
    devices: List<NearsideDevice>,
    onDeviceSelected: (NearsideDevice) -> Unit,
    onDismiss: () -> Unit
) {
    var transferringDevice by remember { mutableStateOf<NearsideDevice?>(null) }
    val scope = rememberCoroutineScope()

    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp)),
        color = MaterialTheme.colorScheme.surface
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(20.dp)
        ) {
            // Header
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column {
                    Text(
                        text = "Share with Nearside",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold
                    )
                    Text(
                        text = summaryText,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                IconButton(onClick = onDismiss) {
                    Icon(Icons.Default.Close, contentDescription = "Close")
                }
            }

            Spacer(modifier = Modifier.height(16.dp))

            if (transferringDevice != null) {
                // Streaming animation
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    CircularProgressIndicator(
                        color = NearsideBlue,
                        modifier = Modifier.size(40.dp)
                    )
                    Spacer(modifier = Modifier.height(12.dp))
                    Text(
                        text = "Sending to ${transferringDevice?.name}...",
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.Medium
                    )
                }
            } else {
                Text(
                    text = "SELECT RECIPIENT",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontWeight = FontWeight.Bold
                )

                Spacer(modifier = Modifier.height(10.dp))

                if (devices.isEmpty()) {
                    Text(
                        text = "No paired devices found. Pair a device in Nearside first.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                } else {
                    LazyRow(
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        items(devices, key = { it.id }) { device ->
                            RecipientDeviceTile(
                                device = device,
                                onClick = {
                                    transferringDevice = device
                                    scope.launch {
                                        delay(1000)
                                        onDeviceSelected(device)
                                    }
                                }
                            )
                        }
                    }
                }
            }

            Spacer(modifier = Modifier.height(12.dp))
        }
    }
}

@Composable
fun RecipientDeviceTile(
    device: NearsideDevice,
    onClick: () -> Unit
) {
    Card(
        modifier = Modifier
            .width(100.dp)
            .clickable(onClick = onClick),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
        shape = RoundedCornerShape(12.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 14.dp, horizontal = 8.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(CircleShape)
                    .background(NearsideBlue.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = if (device.platform == DevicePlatform.MACOS) Icons.Default.Computer else Icons.Default.Smartphone,
                    contentDescription = null,
                    tint = NearsideBlue,
                    modifier = Modifier.size(22.dp)
                )
            }

            Spacer(modifier = Modifier.height(8.dp))

            Text(
                text = device.name,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium,
                maxLines = 1
            )
            Text(
                text = device.platform.displayName,
                fontSize = 10.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}
