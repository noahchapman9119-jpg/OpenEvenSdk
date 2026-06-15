// g2-bridge - Compose UI + runtime permissions.
//
// Binds to BridgeService (which owns the BLE connection + HTTP server), requests
// the runtime permissions Android 12+ needs for BLE, and exposes Connect /
// Disconnect, live status, the LAN server URL, and a text field to push a test
// line to the lens.

package com.g2bridge

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.text.format.Formatter
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {

    private var service: BridgeService? = null
    // Mirror the service's state into a flow the UI collects even before bind.
    private val uiState = MutableStateFlow(G2State(G2Status.DISCONNECTED, "service not bound"))
    private var stateCollectJob: Job? = null

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            val svc = (binder as? BridgeService.LocalBinder)?.service
            service = svc
            if (svc != null) {
                stateCollectJob?.cancel()
                stateCollectJob = lifecycleScope.launch {
                    svc.state.collect { uiState.value = it }
                }
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            service = null
            stateCollectJob?.cancel()
            stateCollectJob = null
        }
    }

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
            if (result.values.all { it }) {
                startAndBindService()
            } else {
                uiState.value = G2State(G2Status.ERROR, "permissions denied")
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    BridgeScreen(
                        state = uiState.collectAsState().value,
                        serverUrl = serverUrl(),
                        onConnect = { ensurePermissionsThen { service?.connectGlasses() } },
                        onDisconnect = { service?.disconnectGlasses() },
                        onSend = { text ->
                            val svc = service ?: return@BridgeScreen
                            lifecycleScope.launch { svc.connection.displayText(text) }
                        },
                    )
                }
            }
        }
        if (hasAllPermissions()) startAndBindService() else ensurePermissionsThen { }
    }

    override fun onDestroy() {
        stateCollectJob?.cancel()
        runCatching { unbindService(serviceConnection) }
        super.onDestroy()
    }

    // ---- service lifecycle --------------------------------------------------
    private fun startAndBindService() {
        val intent = Intent(this, BridgeService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
        else startService(intent)
        bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)
    }

    // ---- permissions --------------------------------------------------------
    private fun requiredPermissions(): Array<String> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            buildList {
                add(Manifest.permission.BLUETOOTH_SCAN)
                add(Manifest.permission.BLUETOOTH_CONNECT)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    add(Manifest.permission.POST_NOTIFICATIONS)
                }
            }.toTypedArray()
        } else {
            arrayOf(
                Manifest.permission.BLUETOOTH,
                Manifest.permission.BLUETOOTH_ADMIN,
                Manifest.permission.ACCESS_FINE_LOCATION,
            )
        }
    }

    private fun hasAllPermissions(): Boolean = requiredPermissions().all {
        ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
    }

    private fun ensurePermissionsThen(onGranted: () -> Unit) {
        if (hasAllPermissions()) { onGranted(); return }
        permissionLauncher.launch(requiredPermissions())
    }

    // ---- server URL ---------------------------------------------------------
    @Suppress("DEPRECATION")
    private fun serverUrl(): String {
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        val ip = wifi?.connectionInfo?.ipAddress ?: 0
        val ipStr = if (ip != 0) Formatter.formatIpAddress(ip) else "<wifi-ip>"
        return "http://$ipStr:${BridgeService.HTTP_PORT}"
    }
}

@Composable
private fun BridgeScreen(
    state: G2State,
    serverUrl: String,
    onConnect: () -> Unit,
    onDisconnect: () -> Unit,
    onSend: (String) -> Unit,
) {
    var text by remember { mutableStateOf("hello from g2-bridge") }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("g2-bridge", style = MaterialTheme.typography.headlineMedium)

        Card(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(16.dp)) {
                Text("Status", style = MaterialTheme.typography.labelMedium)
                Text(state.status.name.lowercase(), style = MaterialTheme.typography.titleLarge)
                if (state.detail.isNotEmpty()) {
                    Text(state.detail, style = MaterialTheme.typography.bodySmall)
                }
            }
        }

        Card(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(16.dp)) {
                Text("HTTP bridge", style = MaterialTheme.typography.labelMedium)
                Text(serverUrl, style = MaterialTheme.typography.titleMedium)
                Text(
                    "POST /text  {\"text\":\"…\"}   ·   POST /image (PNG/JPEG)",
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = onConnect, enabled = state.status != G2Status.READY) {
                Text("Connect")
            }
            Button(onClick = onDisconnect, enabled = state.status != G2Status.DISCONNECTED) {
                Text("Disconnect")
            }
        }

        Spacer(modifier = Modifier.height(8.dp))

        OutlinedTextField(
            value = text,
            onValueChange = { text = it },
            label = { Text("Test text") },
            modifier = Modifier.fillMaxWidth(),
        )
        Button(
            onClick = { onSend(text) },
            enabled = state.status == G2Status.READY,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text("Send to glasses")
        }
    }
}
