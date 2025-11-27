package com.screenreflect.service

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import com.screenreflect.R
import com.screenreflect.ScreenReflectApplication
import com.screenreflect.capture.AudioEncoder
import com.screenreflect.capture.VideoEncoder
import com.screenreflect.network.NetworkServer
import com.screenreflect.network.NsdHelper
import com.screenreflect.ui.MainActivity

/**
 * Foreground service that manages media projection, encoding, and network streaming
 */
class MediaCaptureService : Service() {

    companion object {
        private const val TAG = "MediaCaptureService"
        private const val NOTIFICATION_ID = 1
        const val EXTRA_RESULT_CODE = "result_code"
        const val EXTRA_RESULT_DATA = "result_data"

        const val ACTION_START = "com.screenreflect.START"
        const val ACTION_STOP = "com.screenreflect.STOP"
        
        // Static state for UI persistence
        var isServiceRunning = false
            private set
        var currentServerPort = 0
            private set
    }

    private var mediaProjection: MediaProjection? = null
    private var networkServer: NetworkServer? = null
    private var videoEncoder: VideoEncoder? = null
    private var audioEncoder: AudioEncoder? = null
    private var nsdHelper: NsdHelper? = null

    private var isRunning = false
    private var currentOrientation: Int = Configuration.ORIENTATION_UNDEFINED

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "Service created")
        isServiceRunning = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                if (!isRunning) {
                    startCapture(intent)
                }
            }
            ACTION_STOP -> {
                stopCapture()
                stopSelf()
            }
        }

        return START_NOT_STICKY
    }

    private fun startCapture(intent: Intent) {
        try {
            // Start foreground service with notification
            startForegroundService()

            // Get MediaProjection token
            val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
            val resultData: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(EXTRA_RESULT_DATA)
            }

            Log.d(TAG, "MediaProjection - resultCode: $resultCode, resultData: ${resultData != null}")

            // Note: Activity.RESULT_OK = -1, Activity.RESULT_CANCELED = 0
            if (resultCode == 0 || resultData == null) {
                Log.e(TAG, "Invalid MediaProjection data - resultCode: $resultCode (0=canceled, -1=OK), hasData: ${resultData != null}")
                stopSelf()
                return
            }

            // Create MediaProjection
            val mediaProjectionManager = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            mediaProjection = mediaProjectionManager.getMediaProjection(resultCode, resultData)

            // Register callback for user revoking permission
            mediaProjection?.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    Log.i(TAG, "MediaProjection stopped by user")
                    stopCapture()
                    stopSelf()
                }
            }, null)

            val projection = mediaProjection ?: return

            // Start network server
            networkServer = NetworkServer().apply {
                start()
                // Wait for server to start
                Thread.sleep(500)
            }

            val server = networkServer ?: return
            val port = server.localPort
            currentServerPort = port

            Log.i(TAG, "Network server started on port $port")

            // Update global port
            ScreenReflectApplication.updateServerPort(port)

            // Broadcast port update
            val broadcastIntent = Intent("com.screenreflect.SERVER_PORT_UPDATE").apply {
                putExtra("port", port)
            }
            sendBroadcast(broadcastIntent)

            // Start NSD service discovery
            nsdHelper = NsdHelper(this).apply {
                startPublishing(port)
            }

            // Get screen dimensions and current orientation
            val displayMetrics = resources.displayMetrics
            val screenWidth = displayMetrics.widthPixels
            val screenHeight = displayMetrics.heightPixels
            val screenDpi = displayMetrics.densityDpi
            currentOrientation = resources.configuration.orientation

            val orientationName = when (currentOrientation) {
                Configuration.ORIENTATION_PORTRAIT -> "Portrait"
                Configuration.ORIENTATION_LANDSCAPE -> "Landscape"
                else -> "Unknown"
            }

            Log.i(TAG, "📱 Screen: ${screenWidth}x$screenHeight @ ${screenDpi}dpi ($orientationName)")

            // Start video encoder with actual screen dimensions
            videoEncoder = VideoEncoder(projection, server, screenWidth, screenHeight, screenDpi).apply {
                start()
            }
            
            // Send ACTUAL encoded dimensions to client (may be aligned to 16px boundaries)
            val encoder = videoEncoder
            if (encoder != null) {
                server.sendDimensionUpdate(encoder.encodedWidth, encoder.encodedHeight)
                Log.i(TAG, "📐 Encoded dimensions: ${encoder.encodedWidth}x${encoder.encodedHeight}")
            }

            // Start audio encoder
            audioEncoder = AudioEncoder(projection, server).apply {
                start()
            }

            // Set callback to request keyframe when client connects
            server.onClientConnected = {
                encoder?.requestKeyFrame()
            }

            isRunning = true
            Log.i(TAG, "Screen mirroring started successfully")

            // Update notification
            updateNotification("Streaming to network")

        } catch (e: Exception) {
            Log.e(TAG, "Error starting capture", e)
            stopCapture()
            stopSelf()
        }
    }

    private fun stopCapture() {
        Log.i(TAG, "Stopping capture")
        isRunning = false

        // Stop NSD
        nsdHelper?.stopPublishing()
        nsdHelper = null

        // Stop encoders
        videoEncoder?.stopEncoding()
        videoEncoder = null

        audioEncoder?.stopEncoding()
        audioEncoder = null

        // Close network server
        networkServer?.close()
        networkServer = null
        currentServerPort = 0

        // Stop media projection
        mediaProjection?.stop()
        mediaProjection = null

        Log.i(TAG, "Capture stopped")
    }

    private fun startForegroundService() {
        val notification = createNotification("Starting screen mirroring...")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun updateNotification(message: String) {
        val notification = createNotification(message)
        val notificationManager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.notify(NOTIFICATION_ID, notification)
    }

    private fun createNotification(message: String): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE
        )

        // Stop action
        val stopIntent = Intent(this, MediaCaptureService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPendingIntent = PendingIntent.getService(
            this,
            0,
            stopIntent,
            PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, ScreenReflectApplication.NOTIFICATION_CHANNEL_ID)
            .setContentTitle("Screen Reflect")
            .setContentText(message)
            .setSmallIcon(android.R.drawable.ic_dialog_info)  // Use system icon for now
            .setContentIntent(pendingIntent)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stopPendingIntent)
            .setOngoing(true)
            .build()
    }

    override fun onBind(intent: Intent?): IBinder? {
        return null
    }

    override fun onDestroy() {
        super.onDestroy()
        stopCapture()
        isServiceRunning = false
        Log.i(TAG, "Service destroyed")
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)

        // Check if orientation actually changed
        if (newConfig.orientation != currentOrientation && currentOrientation != Configuration.ORIENTATION_UNDEFINED) {
            val orientationName = when (newConfig.orientation) {
                Configuration.ORIENTATION_PORTRAIT -> "Portrait"
                Configuration.ORIENTATION_LANDSCAPE -> "Landscape"
                else -> "Unknown"
            }

            Log.i(TAG, "📱 Orientation changed to: $orientationName")
            
            // Get new screen dimensions
            val displayMetrics = resources.displayMetrics
            val newWidth = displayMetrics.widthPixels
            val newHeight = displayMetrics.heightPixels
            val screenDpi = displayMetrics.densityDpi
            
            Log.i(TAG, "🔄 New dimensions: ${newWidth}x${newHeight} @ ${screenDpi}dpi")
            
            // Just notify about dimension change - VirtualDisplay auto-adapts
            videoEncoder?.notifyDimensionChange(newWidth, newHeight)
            
            // Send ACTUAL encoded dimensions to client (may be aligned to 16px boundaries)
            val encoder = videoEncoder
            if (encoder != null) {
                networkServer?.sendDimensionUpdate(encoder.encodedWidth, encoder.encodedHeight)
                Log.i(TAG, "📐 Encoded dimensions: ${encoder.encodedWidth}x${encoder.encodedHeight}")
            }
            
            Log.i(TAG, "✅ Dimension change handled")
            
            currentOrientation = newConfig.orientation
            
            // Update notification
            updateNotification("Streaming ${newWidth}x${newHeight} ($orientationName)")
        }
    }
}
