package com.nearside.app.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.FileProvider
import com.nearside.app.R
import com.nearside.app.crypto.PinnedTrustStore
import com.nearside.app.diagnostics.*
import com.nearside.app.model.PayloadType
import com.nearside.app.model.TransferRecord
import com.nearside.app.transfer.TransferEngine
import com.nearside.app.ui.MainActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File
import java.net.ServerSocket
import java.util.UUID

class NearsideReceiverService : Service() {

    companion object {
        const val CHANNEL_ID = "nearside_status_channel_v2"
        const val TRANSFER_CHANNEL_ID = "nearside_transfers_channel"
        const val NOTIFICATION_ID = 2001
        const val TRANSFER_NOTIFICATION_ID = 2002
        const val COMPLETION_NOTIFICATION_ID = 2003

        const val ACTION_START = "com.nearside.app.action.START"
        const val ACTION_STOP = "com.nearside.app.action.STOP"
        const val ACTION_PAUSE = "com.nearside.app.action.PAUSE"
        const val ACTION_RESUME = "com.nearside.app.action.RESUME"
        const val ACTION_REFRESH = "com.nearside.app.action.REFRESH"
        const val ACTION_CANCEL_TRANSFER = "com.nearside.app.action.CANCEL_TRANSFER"

        const val EXTRA_TRANSFER_ID = "com.nearside.app.extra.TRANSFER_ID"

        @Volatile
        var isReceiving: Boolean = true
            private set

        fun start(context: Context) {
            val intent = Intent(context, NearsideReceiverService::class.java).apply {
                action = ACTION_START
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun refresh(context: Context) {
            val intent = Intent(context, NearsideReceiverService::class.java).apply {
                action = ACTION_REFRESH
            }
            context.startService(intent)
        }

        fun pause(context: Context) {
            val intent = Intent(context, NearsideReceiverService::class.java).apply {
                action = ACTION_PAUSE
            }
            context.startService(intent)
        }

        fun resume(context: Context) {
            val intent = Intent(context, NearsideReceiverService::class.java).apply {
                action = ACTION_RESUME
            }
            context.startService(intent)
        }

        fun cancelActiveTransfer(context: Context, transferId: String) {
            val intent = Intent(context, NearsideReceiverService::class.java).apply {
                action = ACTION_CANCEL_TRANSFER
                putExtra(EXTRA_TRANSFER_ID, transferId)
            }
            context.startService(intent)
        }
    }

    private lateinit var powerLockManager: PowerLockManager
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var serverSocket: ServerSocket? = null

    override fun onCreate() {
        super.onCreate()
        powerLockManager = PowerLockManager(this)
        createNotificationChannels()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PAUSE -> {
                isReceiving = false
                powerLockManager.releaseAll()
                stopTcpListener()
                updateNotification(isPaused = true)
                NearsideTileService.requestTileUpdate(this)
            }
            ACTION_RESUME -> {
                isReceiving = true
                startTcpListener()
                updateNotification(isPaused = false)
                NearsideTileService.requestTileUpdate(this)
            }
            ACTION_REFRESH -> {
                updateNotification(isPaused = !isReceiving)
            }
            ACTION_CANCEL_TRANSFER -> {
                val tid = intent.getStringExtra(EXTRA_TRANSFER_ID)
                if (tid != null) {
                    TransferEngine.cancelTransfer(tid)
                }
                clearTransferNotification()
            }
            ACTION_STOP -> {
                isReceiving = false
                powerLockManager.releaseAll()
                stopTcpListener()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                NearsideTileService.requestTileUpdate(this)
                return START_NOT_STICKY
            }
            else -> {
                isReceiving = true
                val notification = buildNotification(isPaused = false)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
                startTcpListener()
                NearsideTileService.requestTileUpdate(this)
            }
        }

        return START_STICKY
    }

    private fun startTcpListener() {
        serviceScope.launch(Dispatchers.IO) {
            stopTcpListener()
            try {
                val socket = ServerSocket(41433)
                serverSocket = socket
                NearsideLogger.info(
                    subsystem = "connection",
                    operation = "startTcpListener",
                    message = "TCP ServerSocket bound to port 41433",
                    state = "listening"
                )
                val trustStore = PinnedTrustStore.fromContext(this@NearsideReceiverService)
                val deviceIdentity = com.nearside.app.crypto.DeviceIdentity.loadOrCreateDefault(this@NearsideReceiverService)
                val destDir = (android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_DOWNLOADS)
                    ?: filesDir).apply { mkdirs() }

                while (isActive && !socket.isClosed) {
                    try {
                        val client = socket.accept()
                        if (!isReceiving) {
                            client.close()
                            continue
                        }
                        serviceScope.launch {
                            val transferTag = "rx_${UUID.randomUUID().toString().take(8)}"
                            powerLockManager.acquire(transferTag)
                            try {
                                val result = TransferEngine.handleInboundConnection(
                                    socket = client,
                                    trustStore = trustStore,
                                    deviceIdentity = deviceIdentity,
                                    destinationDir = destDir,
                                    onProgress = { _, record ->
                                        updateTransferProgressNotification(record)
                                    }
                                )
                                result.onSuccess { record ->
                                    clearTransferNotification()
                                    if (record.payloadText != null) {
                                        handleReceivedTextPayload(record)
                                    } else {
                                        handleReceivedFilePayload(record, destDir)
                                    }
                                }.onFailure {
                                    clearTransferNotification()
                                }
                            } finally {
                                try { client.close() } catch (ignored: Exception) {}
                                powerLockManager.release(transferTag)
                                if (powerLockManager.activeCount == 0) {
                                    updateNotification(isPaused = !isReceiving)
                                }
                            }
                        }
                    } catch (e: Exception) {
                        if (!socket.isClosed) {
                            NearsideLogger.warn(
                                subsystem = "connection",
                                operation = "acceptLoop",
                                message = "Socket accept interrupted or failed",
                                underlyingError = e
                            )
                        }
                        break
                    }
                }
            } catch (e: Exception) {
                NearsideLogger.error(
                    NearsideError(
                        code = NearsideErrorCode.CONNECTION_BIND_FAILED,
                        operation = "startTcpListener",
                        message = "Failed to bind TCP ServerSocket to port 41433: ${e.message}",
                        underlyingError = e
                    ),
                    state = "failed"
                )
            }
        }
    }

    private fun stopTcpListener() {
        try {
            serverSocket?.close()
            NearsideLogger.debug("connection", "stopTcpListener", "Closed TCP ServerSocket")
        } catch (e: Exception) {
            NearsideLogger.warn("connection", "stopTcpListener", "Error closing ServerSocket", underlyingError = e)
        }
        serverSocket = null
    }

    override fun onDestroy() {
        super.onDestroy()
        powerLockManager.releaseAll()
        stopTcpListener()
        serviceScope.cancel()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        NearsideLogger.info("service", "onTaskRemoved", "User swiped app from Recents, maintaining resident foreground receiver")
        if (isReceiving) {
            try {
                val restartIntent = Intent(applicationContext, NearsideReceiverService::class.java).apply {
                    action = ACTION_START
                }
                val restartPendingIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    PendingIntent.getForegroundService(
                        applicationContext,
                        99,
                        restartIntent,
                        PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE
                    )
                } else {
                    PendingIntent.getService(
                        applicationContext,
                        99,
                        restartIntent,
                        PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE
                    )
                }
                val alarmManager = getSystemService(Context.ALARM_SERVICE) as? android.app.AlarmManager
                alarmManager?.set(
                    android.app.AlarmManager.ELAPSED_REALTIME,
                    android.os.SystemClock.elapsedRealtime() + 500,
                    restartPendingIntent
                )
            } catch (e: Exception) {
                NearsideLogger.warn("service", "onTaskRemoved", "Error scheduling alarm restart", underlyingError = e)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)

            val serviceChannel = NotificationChannel(
                CHANNEL_ID,
                getString(R.string.receiving_channel_name),
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = getString(R.string.receiving_channel_desc)
                setShowBadge(true)
            }

            val transferChannel = NotificationChannel(
                TRANSFER_CHANNEL_ID,
                getString(R.string.transfer_channel_name),
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = getString(R.string.transfer_channel_desc)
                setShowBadge(true)
            }

            manager.createNotificationChannel(serviceChannel)
            manager.createNotificationChannel(transferChannel)
        }
    }

    private fun updateNotification(isPaused: Boolean) {
        val manager = getSystemService(NotificationManager::class.java)
        manager?.notify(NOTIFICATION_ID, buildNotification(isPaused))
    }

    private fun updateTransferProgressNotification(record: TransferRecord) {
        val pct = (record.progress * 100).toInt().coerceIn(0, 100)
        val openIntent = Intent(this, MainActivity::class.java)
        val contentPendingIntent = PendingIntent.getActivity(
            this,
            0,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val cancelIntent = Intent(this, NearsideReceiverService::class.java).apply {
            action = ACTION_CANCEL_TRANSFER
            putExtra(EXTRA_TRANSFER_ID, record.id)
        }
        val cancelPendingIntent = PendingIntent.getService(
            this,
            record.id.hashCode(),
            cancelIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val speedText = record.formattedSpeed
        val etaText = record.formattedEta
        val details = listOfNotNull(
            "$pct%",
            if (speedText.isNotEmpty()) speedText else null,
            if (etaText.isNotEmpty()) etaText else null
        ).joinToString(" • ")

        val notification = NotificationCompat.Builder(this, TRANSFER_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_nearside)
            .setContentTitle("Receiving ${record.filename}")
            .setContentText(details)
            .setProgress(100, pct, false)
            .setContentIntent(contentPendingIntent)
            .setOngoing(true)
            .addAction(0, getString(R.string.action_cancel), cancelPendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        val manager = getSystemService(NotificationManager::class.java)
        manager?.notify(TRANSFER_NOTIFICATION_ID, notification)
    }

    private fun clearTransferNotification() {
        val manager = getSystemService(NotificationManager::class.java)
        manager?.cancel(TRANSFER_NOTIFICATION_ID)
    }

    private fun handleReceivedFilePayload(record: TransferRecord, destDir: File) {
        val file = File(destDir, record.filename)
        if (!file.exists()) return

        val manager = getSystemService(NotificationManager::class.java)
        val notifBuilder = NotificationCompat.Builder(this, TRANSFER_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_nearside)
            .setContentTitle(getString(R.string.transfer_complete))
            .setContentText("${record.filename} (${record.formattedSize})")
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setAutoCancel(true)

        try {
            val contentUri: Uri = FileProvider.getUriForFile(
                this,
                "${applicationContext.packageName}.fileprovider",
                file
            )
            val viewIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(contentUri, contentResolver.getType(contentUri) ?: "*/*")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            val openPendingIntent = PendingIntent.getActivity(
                this,
                UUID.randomUUID().hashCode(),
                viewIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            notifBuilder.setContentIntent(openPendingIntent)
            notifBuilder.addAction(0, getString(R.string.action_open), openPendingIntent)
        } catch (ignored: Exception) {}

        manager?.notify(COMPLETION_NOTIFICATION_ID, notifBuilder.build())
    }

    private fun handleReceivedTextPayload(record: TransferRecord) {
        val text = record.payloadText ?: return
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as? android.content.ClipboardManager
        val clip = android.content.ClipData.newPlainText("Nearside Shared Content", text)
        clipboard?.setPrimaryClip(clip)

        val manager = getSystemService(NotificationManager::class.java)
        val notifBuilder = NotificationCompat.Builder(this, TRANSFER_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_nearside)
            .setContentTitle(if (record.payloadType == PayloadType.URL) "Link Copied to Clipboard" else "Text Copied to Clipboard")
            .setContentText(if (text.length > 50) text.take(50) + "..." else text)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)

        if (record.payloadType == PayloadType.URL) {
            try {
                val openIntent = Intent(Intent.ACTION_VIEW, Uri.parse(text)).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                }
                val pi = PendingIntent.getActivity(
                    this,
                    UUID.randomUUID().hashCode(),
                    openIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                notifBuilder.addAction(0, "Open Link", pi)
            } catch (ignored: Exception) {}
        }

        manager?.notify(COMPLETION_NOTIFICATION_ID + 1, notifBuilder.build())
    }

    private fun buildNotification(isPaused: Boolean): Notification {
        val openIntent = Intent(this, MainActivity::class.java)
        val contentPendingIntent = PendingIntent.getActivity(
            this,
            0,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val toggleActionIntent = Intent(this, NearsideReceiverService::class.java).apply {
            action = if (isPaused) ACTION_RESUME else ACTION_PAUSE
        }
        val togglePendingIntent = PendingIntent.getService(
            this,
            1,
            toggleActionIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val toggleLabel = if (isPaused) getString(R.string.action_resume) else getString(R.string.action_pause)
        val statusText = if (isPaused) getString(R.string.status_paused) else getString(R.string.status_ready)

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_nearside)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(statusText)
            .setContentIntent(contentPendingIntent)
            .setOngoing(true)
            .addAction(0, toggleLabel, togglePendingIntent)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()
    }
}
