package com.nearside.probe.e1

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.ServerSocket
import java.net.Socket
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class ReceiverService : Service() {

    companion object {
        const val TAG = "NearsideE1"
        const val CHANNEL_ID = "nearside_receiver_channel"
        const val NOTIFICATION_ID = 1001

        const val ACTION_START = "com.nearside.probe.e1.ACTION_START"
        const val ACTION_PAUSE = "com.nearside.probe.e1.ACTION_PAUSE"
        const val ACTION_RESUME = "com.nearside.probe.e1.ACTION_RESUME"
        const val ACTION_STOP = "com.nearside.probe.e1.ACTION_STOP"

        enum class ServiceState {
            STOPPED,
            STARTING,
            READY,
            PAUSED,
            ERROR
        }

        private val _serviceState = MutableStateFlow(ServiceState.STOPPED)
        val serviceState = _serviceState.asStateFlow()

        private val _boundPort = MutableStateFlow(0)
        val boundPort = _boundPort.asStateFlow()

        private val _nsdRegistered = MutableStateFlow(false)
        val nsdRegistered = _nsdRegistered.asStateFlow()

        private val _connectionCount = MutableStateFlow(0)
        val connectionCount = _connectionCount.asStateFlow()

        private val _eventLogs = MutableSharedFlow<String>(replay = 50)
        val eventLogs = _eventLogs.asSharedFlow()

        fun log(message: String) {
            val timestamp = SimpleDateFormat("HH:mm:ss.SSS", Locale.US).format(Date())
            val line = "[$timestamp] $message"
            Log.i(TAG, line)
            _eventLogs.tryEmit(line)
        }
    }

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var serverSocket: ServerSocket? = null
    private var nsdManager: NsdManager? = null
    private var registrationListener: NsdManager.RegistrationListener? = null

    override fun onCreate() {
        super.onCreate()
        nsdManager = getSystemService(Context.NSD_SERVICE) as NsdManager
        createNotificationChannel()
        log("Service onCreate called")
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_START
        log("onStartCommand received action: $action (flags=$flags, startId=$startId)")

        when (action) {
            ACTION_START, ACTION_RESUME -> {
                handleStartOrResume()
            }
            ACTION_PAUSE -> {
                handlePause()
            }
            ACTION_STOP -> {
                handleStop()
            }
        }

        return START_NOT_STICKY
    }

    private fun handleStartOrResume() {
        _serviceState.value = ServiceState.STARTING
        log("Promoting to foreground service with type CONNECTED_DEVICE")

        val notification = buildNotification(isReady = true)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceCompat.startForeground(
                    this,
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            log("Error starting foreground: ${e.message}")
            _serviceState.value = ServiceState.ERROR
            return
        }

        startListenerAndNsd()
    }

    private fun startListenerAndNsd() {
        // Start TCP ServerSocket
        try {
            serverSocket?.close()
            val socket = ServerSocket(0)
            serverSocket = socket
            val port = socket.localPort
            _boundPort.value = port
            log("TCP ServerSocket bound on port $port")

            serviceScope.launch {
                acceptConnections(socket)
            }

            // Register NSD
            registerNsd(port)

            _serviceState.value = ServiceState.READY
            log("Receiver state is now READY")

            // Update notification with active port
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.notify(NOTIFICATION_ID, buildNotification(isReady = true, port = port))

        } catch (e: Exception) {
            log("Failed to bind ServerSocket: ${e.message}")
            _serviceState.value = ServiceState.ERROR
        }
    }

    private fun acceptConnections(socket: ServerSocket) {
        log("Entering TCP accept loop")
        while (serviceScope.isActive && !socket.isClosed) {
            try {
                val client = socket.accept()
                val remote = "${client.inetAddress.hostAddress}:${client.port}"
                _connectionCount.value += 1
                val currentCount = _connectionCount.value
                log("Accepted connection #$currentCount from $remote")

                serviceScope.launch {
                    handleClient(client, currentCount, remote)
                }
            } catch (e: Exception) {
                if (socket.isClosed) {
                    log("ServerSocket closed, exiting accept loop")
                } else {
                    log("Error in accept loop: ${e.message}")
                }
                break
            }
        }
    }

    private fun handleClient(client: Socket, count: Int, remote: String) {
        try {
            client.soTimeout = 5000
            val reader = BufferedReader(InputStreamReader(client.getInputStream(), Charsets.UTF_8))
            val writer = OutputStreamWriter(client.getOutputStream(), Charsets.UTF_8)

            val line = reader.readLine() ?: "<empty>"
            log("Received from $remote: '$line'")

            val response = "PONG state=${_serviceState.value} count=$count time=${System.currentTimeMillis()}\n"
            writer.write(response)
            writer.flush()
            log("Sent to $remote: '${response.trim()}'")
        } catch (e: Exception) {
            log("Error handling client $remote: ${e.message}")
        } finally {
            try {
                client.close()
            } catch (ignored: Exception) {}
        }
    }

    private fun registerNsd(port: Int) {
        unregisterNsd()

        val serviceInfo = NsdServiceInfo().apply {
            serviceName = "Nearside-Probe-iQOO"
            serviceType = "_nearside._tcp."
            setPort(port)
        }

        registrationListener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(registeredService: NsdServiceInfo) {
                log("NSD registered: name='${registeredService.serviceName}', port=${registeredService.port}")
                _nsdRegistered.value = true
            }

            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                log("NSD registration failed with error code: $errorCode")
                _nsdRegistered.value = false
            }

            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {
                log("NSD unregistered successfully")
                _nsdRegistered.value = false
            }

            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                log("NSD unregistration failed with error code: $errorCode")
            }
        }

        try {
            nsdManager?.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, registrationListener)
            log("Requested NSD registration on port $port")
        } catch (e: Exception) {
            log("Exception calling registerService: ${e.message}")
        }
    }

    private fun unregisterNsd() {
        registrationListener?.let { listener ->
            try {
                nsdManager?.unregisterService(listener)
                log("Requested NSD unregistration")
            } catch (e: Exception) {
                log("Exception unregistering NSD: ${e.message}")
            }
            registrationListener = null
            _nsdRegistered.value = false
        }
    }

    private fun handlePause() {
        log("Executing handlePause (stopping listener and detaching notification)")
        _serviceState.value = ServiceState.PAUSED

        // 1. Unregister NSD
        unregisterNsd()

        // 2. Close TCP ServerSocket
        try {
            serverSocket?.close()
            serverSocket = null
            log("ServerSocket closed")
        } catch (e: Exception) {
            log("Error closing ServerSocket: ${e.message}")
        }
        _boundPort.value = 0

        // 3. Detach notification and stop FGS
        val pausedNotification = buildNotification(isReady = false)
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_DETACH)

        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.notify(NOTIFICATION_ID, pausedNotification)

        log("Service stopped via stopSelf after pause")
        stopSelf()
    }

    private fun handleStop() {
        log("Executing handleStop")
        _serviceState.value = ServiceState.STOPPED
        unregisterNsd()
        try {
            serverSocket?.close()
            serverSocket = null
        } catch (ignored: Exception) {}
        _boundPort.value = 0

        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun buildNotification(isReady: Boolean, port: Int = 0): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val openPendingIntent = PendingIntent.getActivity(
            this,
            0,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val actionTitle = if (isReady) "Pause" else "Resume"
        val actionIntent = Intent(this, ReceiverService::class.java).apply {
            action = if (isReady) ACTION_PAUSE else ACTION_RESUME
        }
        val actionPendingIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PendingIntent.getForegroundService(
                this,
                if (isReady) 1 else 2,
                actionIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } else {
            PendingIntent.getService(
                this,
                if (isReady) 1 else 2,
                actionIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        val contentText = if (isReady) {
            if (port > 0) "Ready to receive (port $port)" else "Ready to receive"
        } else {
            "Paused"
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_nearside)
            .setContentTitle("Nearside")
            .setContentText(contentText)
            .setContentIntent(openPendingIntent)
            .setOngoing(isReady)
            .setAutoCancel(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .addAction(R.drawable.ic_nearside, actionTitle, actionPendingIntent)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                getString(R.string.channel_name),
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = getString(R.string.channel_desc)
                setShowBadge(false)
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        log("Service onDestroy called")
        unregisterNsd()
        try {
            serverSocket?.close()
        } catch (ignored: Exception) {}
        serviceScope.cancel()
        _serviceState.value = ServiceState.STOPPED
        _boundPort.value = 0
    }
}
