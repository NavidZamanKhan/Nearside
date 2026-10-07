package com.nearside.app.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.nearside.app.R
import com.nearside.app.crypto.PinnedTrustStore
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
import java.net.ServerSocket
import java.util.UUID

class NearsideReceiverService : Service() {

    companion object {
        const val CHANNEL_ID = "nearside_receiver_channel"
        const val NOTIFICATION_ID = 2001

        const val ACTION_START = "com.nearside.app.action.START"
        const val ACTION_STOP = "com.nearside.app.action.STOP"
        const val ACTION_PAUSE = "com.nearside.app.action.PAUSE"
        const val ACTION_RESUME = "com.nearside.app.action.RESUME"

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
    }

    private lateinit var powerLockManager: PowerLockManager
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var serverSocket: ServerSocket? = null

    override fun onCreate() {
        super.onCreate()
        powerLockManager = PowerLockManager(this)
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PAUSE -> {
                isReceiving = false
                powerLockManager.releaseAll()
                updateNotification(isPaused = true)
            }
            ACTION_RESUME -> {
                isReceiving = true
                updateNotification(isPaused = false)
            }
            ACTION_STOP -> {
                isReceiving = false
                powerLockManager.releaseAll()
                stopTcpListener()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
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
            }
        }

        return START_STICKY
    }

    private fun startTcpListener() {
        stopTcpListener()
        try {
            val socket = ServerSocket(41433)
            serverSocket = socket
            serviceScope.launch {
                val trustStore = PinnedTrustStore(this@NearsideReceiverService)
                val destDir = android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_DOWNLOADS)
                    ?: filesDir

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
                                    destinationDir = destDir,
                                    onProgress = { progress, record ->
                                        updateTransferProgressNotification(record.filename, progress)
                                    }
                                )
                                result.onSuccess { record ->
                                    if (record.payloadText != null) {
                                        handleReceivedTextPayload(record)
                                    }
                                }
                            } finally {
                                powerLockManager.release(transferTag)
                                if (powerLockManager.activeCount == 0) {
                                    updateNotification(isPaused = false)
                                }
                            }
                        }
                    } catch (e: Exception) {
                        break
                    }
                }
            }
        } catch (e: Exception) {
            // Port already in use or test mode
        }
    }

    private fun stopTcpListener() {
        try {
            serverSocket?.close()
        } catch (ignored: Exception) {}
        serverSocket = null
    }

    override fun onDestroy() {
        super.onDestroy()
        powerLockManager.releaseAll()
        stopTcpListener()
        serviceScope.cancel()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                getString(R.string.receiving_channel_name),
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = getString(R.string.receiving_channel_desc)
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun updateNotification(isPaused: Boolean) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(isPaused))
    }

    private fun updateTransferProgressNotification(filename: String, progress: Float) {
        val pct = (progress * 100).toInt().coerceIn(0, 100)
        val openIntent = Intent(this, MainActivity::class.java)
        val contentPendingIntent = PendingIntent.getActivity(
            this,
            0,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_nearside)
            .setContentTitle(getString(R.string.app_name))
            .setContentText("Receiving $filename ($pct%)")
            .setProgress(100, pct, false)
            .setContentIntent(contentPendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        val manager = getSystemService(NotificationManager::class.java)
        manager?.notify(NOTIFICATION_ID, notification)
    }

    private fun handleReceivedTextPayload(record: TransferRecord) {
        val text = record.payloadText ?: return
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as? android.content.ClipboardManager
        val clip = android.content.ClipData.newPlainText("Nearside Shared Content", text)
        clipboard?.setPrimaryClip(clip)

        val manager = getSystemService(NotificationManager::class.java)
        val notifBuilder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_nearside)
            .setContentTitle(if (record.payloadType == PayloadType.URL) "Link Copied to Clipboard" else "Text Copied to Clipboard")
            .setContentText(if (text.length > 50) text.take(50) + "..." else text)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)

        if (record.payloadType == PayloadType.URL) {
            try {
                val openIntent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(text)).apply {
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

        manager?.notify(NOTIFICATION_ID + 1, notifBuilder.build())
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
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }
}
