package com.nearside.probe.e1

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.nearside.probe.e1.databinding.ActivityMainBinding
import kotlinx.coroutines.launch
import java.net.Inet4Address
import java.net.NetworkInterface

class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding

    private val requestNotificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { isGranted ->
            ReceiverService.log("Notification permission result: isGranted=$isGranted")
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        ReceiverService.log("MainActivity onCreate")

        checkNotificationPermission()
        setupButtons()
        observeState()
        handleIntentCommands(intent)
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        intent?.let { handleIntentCommands(it) }
    }

    private fun handleIntentCommands(intent: Intent) {
        val cmd = intent.getStringExtra("COMMAND") ?: if (intent.getBooleanExtra("AUTO_START", false)) "START" else null
        ReceiverService.log("MainActivity handleIntentCommands: COMMAND=$cmd")
        when (cmd) {
            "START" -> {
                val serviceIntent = Intent(this, ReceiverService::class.java).apply {
                    action = ReceiverService.ACTION_START
                }
                ContextCompat.startForegroundService(this, serviceIntent)
            }
            "STOP" -> {
                val serviceIntent = Intent(this, ReceiverService::class.java).apply {
                    action = ReceiverService.ACTION_STOP
                }
                startService(serviceIntent)
            }
            "PAUSE" -> {
                val serviceIntent = Intent(this, ReceiverService::class.java).apply {
                    action = ReceiverService.ACTION_PAUSE
                }
                startService(serviceIntent)
            }
            "RESUME" -> {
                val serviceIntent = Intent(this, ReceiverService::class.java).apply {
                    action = ReceiverService.ACTION_RESUME
                }
                ContextCompat.startForegroundService(this, serviceIntent)
            }
        }
    }

    private fun checkNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val status = ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
            if (status != PackageManager.PERMISSION_GRANTED) {
                ReceiverService.log("Requesting POST_NOTIFICATIONS permission")
                requestNotificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
    }

    private fun setupButtons() {
        binding.btnStart.setOnClickListener {
            val intent = Intent(this, ReceiverService::class.java).apply {
                action = ReceiverService.ACTION_START
            }
            ContextCompat.startForegroundService(this, intent)
        }

        binding.btnStop.setOnClickListener {
            val intent = Intent(this, ReceiverService::class.java).apply {
                action = ReceiverService.ACTION_STOP
            }
            startService(intent)
        }

        binding.btnPause.setOnClickListener {
            val intent = Intent(this, ReceiverService::class.java).apply {
                action = ReceiverService.ACTION_PAUSE
            }
            startService(intent)
        }

        binding.btnResume.setOnClickListener {
            val intent = Intent(this, ReceiverService::class.java).apply {
                action = ReceiverService.ACTION_RESUME
            }
            ContextCompat.startForegroundService(this, intent)
        }
    }

    private fun observeState() {
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch {
                    ReceiverService.serviceState.collect { state ->
                        binding.textState.text = "State: ${state.name}"
                        val colorRes = when (state) {
                            ReceiverService.Companion.ServiceState.READY -> R.color.status_green
                            ReceiverService.Companion.ServiceState.PAUSED,
                            ReceiverService.Companion.ServiceState.STARTING -> R.color.status_amber
                            ReceiverService.Companion.ServiceState.STOPPED,
                            ReceiverService.Companion.ServiceState.ERROR -> R.color.status_red
                        }
                        binding.textState.setTextColor(ContextCompat.getColor(this@MainActivity, colorRes))
                    }
                }

                launch {
                    ReceiverService.boundPort.collect { port ->
                        val ip = getLocalIpAddress()
                        binding.textEndpoint.text = if (port > 0) {
                            "Endpoint: $ip:$port"
                        } else {
                            "Endpoint: Not listening"
                        }
                    }
                }

                launch {
                    ReceiverService.nsdRegistered.collect { registered ->
                        binding.textNsd.text = if (registered) {
                            "NSD: Active (_nearside._tcp on LAN)"
                        } else {
                            "NSD: Inactive"
                        }
                    }
                }

                launch {
                    ReceiverService.connectionCount.collect { count ->
                        binding.textStats.text = "Connections received: $count"
                    }
                }

                launch {
                    ReceiverService.eventLogs.collect { line ->
                        binding.textLogs.append("$line\n")
                        binding.scrollView.post {
                            binding.scrollView.fullScroll(android.view.View.FOCUS_DOWN)
                        }
                    }
                }
            }
        }
    }

    private fun getLocalIpAddress(): String {
        try {
            val interfaces = NetworkInterface.getNetworkInterfaces()
            while (interfaces.hasMoreElements()) {
                val iface = interfaces.nextElement()
                if (iface.name.contains("wlan", ignoreCase = true) || iface.name.contains("eth", ignoreCase = true)) {
                    val addresses = iface.inetAddresses
                    while (addresses.hasMoreElements()) {
                        val addr = addresses.nextElement()
                        if (!addr.isLoopbackAddress && addr is Inet4Address) {
                            return addr.hostAddress ?: "127.0.0.1"
                        }
                    }
                }
            }
        } catch (ignored: Exception) {}
        return "127.0.0.1"
    }

    override fun onDestroy() {
        super.onDestroy()
        ReceiverService.log("MainActivity onDestroy")
    }
}
