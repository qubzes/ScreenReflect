package com.screenreflect

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build

/**
 * Application class for Screen Reflect
 * Initializes notification channels required for foreground service
 */
class ScreenReflectApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Screen Reflect Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Notification for screen mirroring service"
                setShowBadge(false)
            }

            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager?.createNotificationChannel(channel)
        }
    }

    companion object {
        const val NOTIFICATION_CHANNEL_ID = "screen_reflect_channel"

        // Shared state for server port
        var serverPort: Int = 0
            private set

        private var portUpdateCallback: ((Int) -> Unit)? = null

        fun updateServerPort(port: Int) {
            serverPort = port
            portUpdateCallback?.invoke(port)
        }

        fun setPortUpdateCallback(callback: (Int) -> Unit) {
            portUpdateCallback = callback
            // If port is already set, call the callback immediately
            if (serverPort > 0) {
                callback(serverPort)
            }
        }

        fun clearPortUpdateCallback() {
            portUpdateCallback = null
        }
    }
}
