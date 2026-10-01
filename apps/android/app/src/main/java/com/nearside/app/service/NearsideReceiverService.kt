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
import com.nearside.app.ui.MainActivity

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

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PAUSE -> {
                isReceiving = false
                updateNotification(isPaused = true)
            }
            ACTION_RESUME -> {
                isReceiving = true
                updateNotification(isPaused = false)
            }
            ACTION_STOP -> {
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
            }
        }

        return START_STICKY
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
