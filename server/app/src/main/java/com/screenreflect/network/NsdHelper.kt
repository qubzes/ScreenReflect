package com.screenreflect.network

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.util.Log

/**
 * Helper class for Network Service Discovery (Bonjour/mDNS)
 * Publishes the server on the local network for automatic discovery by macOS client
 */
class NsdHelper(private val context: Context) {

    companion object {
        private const val TAG = "NsdHelper"
        private const val SERVICE_TYPE = "_screenreflect._tcp."
        private const val SERVICE_NAME_PREFIX = "Screen Reflect"
    }

    private var nsdManager: NsdManager? = null
    private var serviceInfo: NsdServiceInfo? = null

    private val registrationListener = object : NsdManager.RegistrationListener {

        override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
            val serviceName = serviceInfo.serviceName
            Log.i(TAG, "Service registered: $serviceName")
        }

        override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
            Log.e(TAG, "Service registration failed: $errorCode")
        }

        override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {
            Log.i(TAG, "Service unregistered: ${serviceInfo.serviceName}")
        }

        override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
            Log.e(TAG, "Service unregistration failed: $errorCode")
        }
    }

    /**
     * Start advertising the service on the local network
     */
    fun startPublishing(port: Int) {
        try {
            nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager

            // Create service info
            val deviceModel = Build.MODEL
            serviceInfo = NsdServiceInfo().apply {
                serviceName = "$SERVICE_NAME_PREFIX - $deviceModel"
                serviceType = SERVICE_TYPE
                setPort(port)
            }

            Log.i(TAG, "Registering NSD service on port $port...")

            // Register service
            nsdManager?.registerService(
                serviceInfo,
                NsdManager.PROTOCOL_DNS_SD,
                registrationListener
            )

        } catch (e: Exception) {
            Log.e(TAG, "Error starting NSD publishing", e)
        }
    }

    /**
     * Stop advertising the service
     */
    fun stopPublishing() {
        try {
            nsdManager?.unregisterService(registrationListener)
            Log.i(TAG, "NSD service stopped")
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping NSD publishing", e)
        }
    }
}
