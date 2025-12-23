package com.screenreflect.network

import android.util.Log
import java.io.OutputStream
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Real-time network server for screen mirroring.
 *
 * Key design principles:
 * - BOUNDED LATENCY: Small queue (5 frames max) keeps us close to real-time
 * - DROP OLDEST: When queue is full, drop oldest frame (not newest) to stay current
 * - PRESERVE QUALITY: Don't drop frames unnecessarily - only when truly behind
 * - Priority ordering: Config > Dimension > Video > Audio
 */
class NetworkServer : Thread() {

    companion object {
        private const val TAG = "NetworkServer"
        const val PACKET_TYPE_CONFIG: Byte = 0x00
        const val PACKET_TYPE_VIDEO: Byte = 0x01
        const val PACKET_TYPE_AUDIO: Byte = 0x02
        const val PACKET_TYPE_AUDIO_CONFIG: Byte = 0x03
        const val PACKET_TYPE_DIMENSION: Byte = 0x04

        // Small queue = low latency. At 60fps, 5 frames = ~83ms max latency
        private const val VIDEO_QUEUE_SIZE = 5
        private const val AUDIO_QUEUE_SIZE = 8
    }

    private var serverSocket: ServerSocket? = null
    private var clientSocket: Socket? = null
    private var outputStream: OutputStream? = null
    @Volatile private var running = false

    val localPort: Int
        get() = serverSocket?.localPort ?: 0

    // High-priority packets (must be sent, guaranteed delivery)
    private val pendingConfigPacket = AtomicReference<ByteArray?>(null)
    private val pendingAudioConfigPacket = AtomicReference<ByteArray?>(null)
    private val pendingDimensionPacket = AtomicReference<ByteArray?>(null)

    // Bounded queues for video/audio - drops OLDEST when full (not newest!)
    // This keeps latency bounded while preserving as many frames as possible
    private val videoQueue = ArrayBlockingQueue<ByteArray>(VIDEO_QUEUE_SIZE)
    private val audioQueue = ArrayBlockingQueue<ByteArray>(AUDIO_QUEUE_SIZE)

    // Cached packets for new client connections
    @Volatile private var cachedConfigPacket: ByteArray? = null
    @Volatile private var cachedAudioConfigPacket: ByteArray? = null
    @Volatile private var cachedKeyFramePacket: ByteArray? = null

    // Signal that new data is available
    @Volatile private var hasNewData = false
    private val dataLock = ReentrantLock()
    private val dataCondition = dataLock.newCondition()

    @Volatile var onClientConnected: (() -> Unit)? = null

    override fun run() {
        try {
            serverSocket = ServerSocket(0).apply { reuseAddress = true }

            running = true

            while (running && !isInterrupted) {
                try {
                    Log.i(TAG, "Waiting for client connection...")
                    clientSocket =
                            serverSocket?.accept()?.apply {
                                keepAlive = true
                                tcpNoDelay = true // Critical: Disable Nagle's algorithm
                                sendBufferSize = 1024 * 1024 // 1MB send buffer
                                receiveBufferSize = 64 * 1024
                                soTimeout = 0
                            }

                    if (clientSocket == null) continue

                    Log.i(TAG, "Client connected: ${clientSocket?.inetAddress}")
                    outputStream = clientSocket?.getOutputStream()

                    // Clear any stale packets
                    clearAllPackets()

                    // Send cached config packets immediately
                    cachedConfigPacket?.let { sendPacketInternal(PACKET_TYPE_CONFIG, it) }
                    cachedAudioConfigPacket?.let {
                        sendPacketInternal(PACKET_TYPE_AUDIO_CONFIG, it)
                    }

                    // Send last keyframe immediately
                    cachedKeyFramePacket?.let {
                        Log.i(TAG, "Sending cached keyframe (${it.size} bytes)")
                        sendPacketInternal(PACKET_TYPE_VIDEO, it)
                    }

                    onClientConnected?.invoke()

                    // Real-time send loop
                    sendLoop()
                } catch (e: Exception) {
                    if (running) {
                        Log.e(TAG, "Error accepting client", e)
                        Thread.sleep(500)
                    }
                } finally {
                    cleanupClient()
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Server fatal error", e)
        } finally {
            close()
        }
    }

    /**
     * Real-time send loop with quality preservation. Priority order: Config > AudioConfig >
     * Dimension > Video > Audio Sends ALL queued frames in order for smooth playback.
     */
    private fun sendLoop() {
        try {
            while (running &&
                    clientSocket != null &&
                    !clientSocket!!.isClosed &&
                    clientSocket!!.isConnected) {
                var sentSomething = false

                // 1. Highest priority: Config packets (must be delivered)
                pendingConfigPacket.getAndSet(null)?.let { data ->
                    sendPacketInternal(PACKET_TYPE_CONFIG, data)
                    sentSomething = true
                }

                pendingAudioConfigPacket.getAndSet(null)?.let { data ->
                    sendPacketInternal(PACKET_TYPE_AUDIO_CONFIG, data)
                    sentSomething = true
                }

                // 2. High priority: Dimension updates
                pendingDimensionPacket.getAndSet(null)?.let { data ->
                    sendPacketInternal(PACKET_TYPE_DIMENSION, data)
                    sentSomething = true
                }

                // 3. Video frames - send all queued frames in order
                var videoFrame = videoQueue.poll()
                while (videoFrame != null) {
                    sendPacketInternal(PACKET_TYPE_VIDEO, videoFrame)
                    sentSomething = true
                    videoFrame = videoQueue.poll()
                }

                // 4. Audio frames - send all queued frames in order
                var audioFrame = audioQueue.poll()
                while (audioFrame != null) {
                    sendPacketInternal(PACKET_TYPE_AUDIO, audioFrame)
                    sentSomething = true
                    audioFrame = audioQueue.poll()
                }

                // If nothing to send, wait briefly for new data
                if (!sentSomething) {
                    dataLock.withLock {
                        if (!hasNewData) {
                            // Wait up to 1ms for new data, then check again
                            dataCondition.awaitNanos(1_000_000L)
                        }
                        hasNewData = false
                    }
                }
            }
        } catch (e: InterruptedException) {
            Log.i(TAG, "Send loop interrupted")
        } catch (e: Exception) {
            Log.e(TAG, "Send loop error", e)
        }
    }

    /**
     * Submit a packet for sending. Video/Audio: Added to bounded queue. If queue full, DROP OLDEST
     * frame (not newest). Config/Dimension: Stored until sent (guaranteed delivery)
     */
    fun sendPacket(type: Byte, data: ByteArray, isKeyFrame: Boolean = false) {
        // Cache for new connections
        when (type) {
            PACKET_TYPE_CONFIG -> cachedConfigPacket = data
            PACKET_TYPE_AUDIO_CONFIG -> cachedAudioConfigPacket = data
            PACKET_TYPE_VIDEO -> if (isKeyFrame) cachedKeyFramePacket = data
        }

        if (!running || outputStream == null) return

        when (type) {
            PACKET_TYPE_CONFIG -> pendingConfigPacket.set(data)
            PACKET_TYPE_AUDIO_CONFIG -> pendingAudioConfigPacket.set(data)
            PACKET_TYPE_VIDEO -> {
                // If queue is full, drop OLDEST frame to make room
                while (!videoQueue.offer(data)) {
                    videoQueue.poll() // Remove oldest
                }
            }
            PACKET_TYPE_AUDIO -> {
                // If queue is full, drop OLDEST frame to make room
                while (!audioQueue.offer(data)) {
                    audioQueue.poll() // Remove oldest
                }
            }
        }

        // Signal that new data is available
        signalNewData()
    }

    /** Send dimension update (high priority, guaranteed delivery) */
    fun sendDimensionUpdate(width: Int, height: Int) {
        Log.i(TAG, "Sending dimension update: ${width}x${height}")
        val buffer = ByteBuffer.allocate(8)
        buffer.putInt(width)
        buffer.putInt(height)
        pendingDimensionPacket.set(buffer.array())
        signalNewData()
    }

    private fun signalNewData() {
        dataLock.withLock {
            hasNewData = true
            dataCondition.signal()
        }
    }

    private fun sendPacketInternal(type: Byte, data: ByteArray) {
        try {
            val stream = outputStream ?: return
            val socket = clientSocket ?: return

            if (socket.isClosed || !socket.isConnected) return

            // Write type (1 byte)
            stream.write(type.toInt())

            // Write length (4 bytes, big-endian)
            val lengthBuffer = ByteBuffer.allocate(4)
            lengthBuffer.putInt(data.size)
            stream.write(lengthBuffer.array())

            // Write data
            stream.write(data)

            // Flush for minimal latency
            stream.flush()
        } catch (e: Exception) {
            throw e
        }
    }

    private fun clearAllPackets() {
        pendingConfigPacket.set(null)
        pendingAudioConfigPacket.set(null)
        pendingDimensionPacket.set(null)
        videoQueue.clear()
        audioQueue.clear()
    }

    private fun cleanupClient() {
        try {
            outputStream?.close()
            outputStream = null
            clientSocket?.close()
            clientSocket = null
        } catch (e: Exception) {
            Log.e(TAG, "Error cleaning up client", e)
        }
    }

    fun close() {
        running = false
        interrupt()
        signalNewData() // Wake up send loop

        try {
            serverSocket?.close()
            serverSocket = null
        } catch (e: Exception) {
            Log.e(TAG, "Error closing server socket", e)
        }

        cleanupClient()
        clearAllPackets()
    }
}
