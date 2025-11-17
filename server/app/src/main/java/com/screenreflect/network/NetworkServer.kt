package com.screenreflect.network

import android.util.Log
import java.io.OutputStream
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.BlockingQueue
import java.util.concurrent.LinkedBlockingQueue

/**
 * TCP server that handles client connections and streams multiplexed audio/video data
 * Uses a custom packet protocol for frame demultiplexing
 */
class NetworkServer : Thread() {

    companion object {
        private const val TAG = "NetworkServer"

        // Packet types
        const val PACKET_TYPE_CONFIG: Byte = 0x00  // H.264 SPS/PPS configuration
        const val PACKET_TYPE_VIDEO: Byte = 0x01   // H.264 video frame
        const val PACKET_TYPE_AUDIO: Byte = 0x02   // AAC audio frame
        const val PACKET_TYPE_AUDIO_CONFIG: Byte = 0x03  // AAC AudioSpecificConfig (CSD-0)
    }

    private var serverSocket: ServerSocket? = null
    private var clientSocket: Socket? = null
    private var outputStream: OutputStream? = null
    private var running = false

    val localPort: Int
        get() = serverSocket?.localPort ?: 0

    // Queue for packets to be sent - LIMITED SIZE to prevent buffering lag
    private val packetQueue: BlockingQueue<Packet> = LinkedBlockingQueue(30)  // Max 30 packets (~0.5s at 60fps)

    // Cached H.264 config (SPS/PPS) to send to newly connected clients
    @Volatile
    private var cachedConfigPacket: ByteArray? = null

    // Cached AAC AudioSpecificConfig to send to newly connected clients
    @Volatile
    private var cachedAudioConfigPacket: ByteArray? = null

    // Callback to request keyframe when client connects
    @Volatile
    var onClientConnected: (() -> Unit)? = null

    data class Packet(
        val type: Byte,
        val data: ByteArray
    )

    override fun run() {
        try {
            // Bind to any available port
            serverSocket = ServerSocket(0).apply {
                reuseAddress = true
            }

            val port = localPort
            Log.i(TAG, "Server started on port $port")

            running = true

            // Accept client connection
            Log.i(TAG, "Waiting for client connection...")
            clientSocket = serverSocket?.accept()?.apply {
                // Enable TCP keepalive to detect dead connections
                keepAlive = true
                tcpNoDelay = true  // Disable Nagle's algorithm for lower latency
                // Set socket buffer sizes for better throughput
                sendBufferSize = 256 * 1024  // 256KB send buffer
            }
            Log.i(TAG, "Client connected: ${clientSocket?.inetAddress}")

            outputStream = clientSocket?.getOutputStream()?.apply {
                // Enable buffering with optimal buffer size for streaming
                // This helps batch small writes for better network efficiency
            }

            // Send cached config packets immediately if available
            cachedConfigPacket?.let { configData ->
                Log.i(TAG, "Sending cached VIDEO CONFIG packet to new client (${configData.size} bytes)")
                sendPacketInternal(PACKET_TYPE_CONFIG, configData)
            }

            cachedAudioConfigPacket?.let { audioConfigData ->
                Log.i(TAG, "Sending cached AUDIO CONFIG packet to new client (${audioConfigData.size} bytes)")
                sendPacketInternal(PACKET_TYPE_AUDIO_CONFIG, audioConfigData)
            }

            // Notify that client connected (to request keyframe)
            onClientConnected?.invoke()
            Log.d(TAG, "Triggered client connected callback")

            // Start packet sender thread
            Thread {
                try {
                    while (running && outputStream != null) {
                        val packet = packetQueue.take()
                        sendPacketInternal(packet.type, packet.data)
                    }
                } catch (e: InterruptedException) {
                    Log.d(TAG, "Packet sender interrupted")
                } catch (e: Exception) {
                    Log.e(TAG, "Error in packet sender", e)
                }
            }.start()

            // Keep alive
            while (running) {
                Thread.sleep(1000)
            }

        } catch (e: Exception) {
            Log.e(TAG, "Server error", e)
        } finally {
            close()
        }
    }

    /**
     * Queue a packet to be sent to the client
     * Thread-safe method called by encoder threads
     * With frame dropping for smooth playback
     */
    fun sendPacket(type: Byte, data: ByteArray) {
        // Cache config packets for new clients
        if (type == PACKET_TYPE_CONFIG) {
            cachedConfigPacket = data
            Log.d(TAG, "Cached VIDEO CONFIG packet (${data.size} bytes)")
        }

        if (type == PACKET_TYPE_AUDIO_CONFIG) {
            cachedAudioConfigPacket = data
            Log.d(TAG, "Cached AUDIO CONFIG packet (${data.size} bytes)")
        }

        if (running && outputStream != null) {
            // Always send config packets
            if (type == PACKET_TYPE_CONFIG || type == PACKET_TYPE_AUDIO_CONFIG) {
                packetQueue.offer(Packet(type, data))
                return
            }

            // For video/audio frames: drop if queue is full (prevents lag buildup)
            if (!packetQueue.offer(Packet(type, data))) {
                if (type == PACKET_TYPE_VIDEO) {
                    Log.v(TAG, "⚠️ Dropped video frame - queue full (preventing lag)")
                }
            }
        }
    }

    /**
     * Internal packet sending with custom protocol:
     * [1 byte: Type][4 bytes: Length (big-endian)][N bytes: Data]
     */
    @Synchronized
    private fun sendPacketInternal(type: Byte, data: ByteArray) {
        try {
            val stream = outputStream ?: return

            // Check if client is still connected
            val socket = clientSocket
            if (socket == null || socket.isClosed || !socket.isConnected) {
                Log.w(TAG, "Client disconnected, stopping packet sender")
                running = false
                return
            }

            // Write packet type (1 byte)
            stream.write(type.toInt())

            // Write data length (4 bytes, big-endian)
            val lengthBuffer = ByteBuffer.allocate(4)
            lengthBuffer.putInt(data.size)
            stream.write(lengthBuffer.array())

            // Write data payload
            stream.write(data)
            stream.flush()

            // Log only config packets to avoid spam
            if (type == PACKET_TYPE_CONFIG) {
                Log.d(TAG, "Sent VIDEO CONFIG packet (${data.size} bytes)")
            } else if (type == PACKET_TYPE_AUDIO_CONFIG) {
                Log.d(TAG, "Sent AUDIO CONFIG packet (${data.size} bytes)")
            }

        } catch (e: java.net.SocketException) {
            // Client disconnected
            Log.w(TAG, "Client disconnected: ${e.message}")
            running = false
        } catch (e: Exception) {
            Log.e(TAG, "Error sending packet", e)
            running = false
        }
    }

    /**
     * Stop the server and close all connections
     */
    fun close() {
        Log.i(TAG, "Closing server")
        running = false

        try {
            outputStream?.close()
            clientSocket?.close()
            serverSocket?.close()
        } catch (e: Exception) {
            Log.e(TAG, "Error closing server", e)
        }

        packetQueue.clear()
        cachedConfigPacket = null
        cachedAudioConfigPacket = null
    }
}
