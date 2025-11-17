package com.screenreflect.ui

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.screenreflect.ScreenReflectApplication
import com.screenreflect.service.MediaCaptureService
import com.screenreflect.ui.theme.ScreenReflectTheme
// Add required imports for icons
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Stop

/**
 * Main activity - minimalist UI for controlling screen mirroring
 */
@OptIn(ExperimentalMaterial3Api::class)
class MainActivity : ComponentActivity() {

    private val viewModel: MainViewModel by viewModels()

    private lateinit var mediaProjectionManager: MediaProjectionManager

    // Launcher for MediaProjection permission
    private val mediaProjectionLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        android.util.Log.d("MainActivity", "MediaProjection result - code: ${result.resultCode}, RESULT_OK: ${Activity.RESULT_OK}, data: ${result.data}")

        if (result.resultCode == Activity.RESULT_OK) {
            val data = result.data
            if (data != null) {
                startCaptureService(result.resultCode, data)
                viewModel.updateStreamingState(true)
                viewModel.updateStatus("Starting stream...")
            } else {
                viewModel.updateStatus("Screen capture permission denied - no data")
            }
        } else {
            viewModel.updateStatus("Screen capture permission denied - result code: ${result.resultCode}, expected: ${Activity.RESULT_OK}")
        }
    }

    // Launcher for audio permission
    private val audioPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) {
            // Audio permission granted, proceed with media projection
            requestScreenCapture()
        } else {
            viewModel.updateStatus("Audio permission required for streaming")
        }
    }

    // Launcher for notification permission (Android 13+)
    private val notificationPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) {
            viewModel.updateStatus("Notification permission granted")
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        mediaProjectionManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager

        // Set up port update callback
        ScreenReflectApplication.setPortUpdateCallback { port ->
            runOnUiThread {
                viewModel.updateConnectionInfo(port)
            }
        }

        // Request notification permission on Android 13+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.POST_NOTIFICATIONS
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
        }

        setContent {
            ScreenReflectTheme {
                ScreenReflectApp(
                    viewModel = viewModel,
                    onStartClick = { handleStartClick() },
                    onStopClick = { handleStopClick() }
                )
            }
        }
    }

    private fun handleStartClick() {
        // Show instruction dialog first
        AlertDialog.Builder(this)
            .setTitle("Screen Capture Permission")
            .setMessage("After tapping OK, you will see a system dialog.\n\n" +
                    "⚠️ IMPORTANT: You MUST tap \"Start now\" (not Cancel) to allow screen capture.\n\n" +
                    "If you tap Cancel, streaming will fail.")
            .setPositiveButton("OK") { _, _ ->
                // Check audio permission first
                if (ContextCompat.checkSelfPermission(
                        this,
                        Manifest.permission.RECORD_AUDIO
                    ) != PackageManager.PERMISSION_GRANTED
                ) {
                    audioPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                } else {
                    requestScreenCapture()
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun requestScreenCapture() {
        viewModel.updateStatus("Requesting screen capture permission...")
        val captureIntent = mediaProjectionManager.createScreenCaptureIntent()
        mediaProjectionLauncher.launch(captureIntent)
    }

    private fun handleStopClick() {
        val intent = Intent(this, MediaCaptureService::class.java).apply {
            action = MediaCaptureService.ACTION_STOP
        }
        startService(intent)
        viewModel.updateStreamingState(false)
    }

    private fun startCaptureService(resultCode: Int, data: Intent) {
        val intent = Intent(this, MediaCaptureService::class.java).apply {
            action = MediaCaptureService.ACTION_START
            putExtra(MediaCaptureService.EXTRA_RESULT_CODE, resultCode)
            putExtra(MediaCaptureService.EXTRA_RESULT_DATA, data)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        ScreenReflectApplication.clearPortUpdateCallback()
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ScreenReflectApp(
    viewModel: MainViewModel,
    onStartClick: () -> Unit,
    onStopClick: () -> Unit
) {
    val uiState by viewModel.uiState.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Screen Reflect") },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.primary,
                    titleContentColor = MaterialTheme.colorScheme.onPrimary
                )
            )
        }
    ) { paddingValues ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            // Status icon
            Icon(
                imageVector = if (uiState.isStreaming) {
                    Icons.Default.Stop
                } else {
                    Icons.Default.PlayArrow
                },
                contentDescription = null,
                modifier = Modifier.size(80.dp),
                tint = if (uiState.isStreaming) {
                    MaterialTheme.colorScheme.error
                } else {
                    MaterialTheme.colorScheme.primary
                }
            )

            Spacer(modifier = Modifier.height(24.dp))

            // Status text
            Text(
                text = uiState.statusText,
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurface
            )

            Spacer(modifier = Modifier.height(40.dp))

            // Start/Stop button
            Button(
                onClick = {
                    if (uiState.isStreaming) {
                        onStopClick()
                    } else {
                        onStartClick()
                    }
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(56.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = if (uiState.isStreaming) {
                        MaterialTheme.colorScheme.error
                    } else {
                        MaterialTheme.colorScheme.primary
                    }
                )
            ) {
                Text(
                    text = if (uiState.isStreaming) "Stop Streaming" else "Start Streaming",
                    style = MaterialTheme.typography.titleMedium
                )
            }

            if (!uiState.isStreaming) {
                Spacer(modifier = Modifier.height(16.dp))

                Text(
                    text = "Ensure your macOS device is on the same network",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            } else {
                Spacer(modifier = Modifier.height(24.dp))

                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.surfaceVariant
                    )
                ) {
                    Column(
                        modifier = Modifier.padding(16.dp)
                    ) {
                        Text(
                            text = "Connection Info",
                            style = MaterialTheme.typography.titleSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )

                        Spacer(modifier = Modifier.height(8.dp))

                        Text(
                            text = "Server Port: ${uiState.serverPort}",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurface
                        )

                        Spacer(modifier = Modifier.height(8.dp))

                        Text(
                            text = "For emulator: Run this command on your Mac:",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )

                        Spacer(modifier = Modifier.height(4.dp))

                        Text(
                            text = "adb forward tcp:${uiState.serverPort} tcp:${uiState.serverPort}",
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                            color = MaterialTheme.colorScheme.primary
                        )

                        Spacer(modifier = Modifier.height(8.dp))

                        Text(
                            text = "Then use Manual Connect with:\nHost: 127.0.0.1\nPort: ${uiState.serverPort}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }
    }
}
