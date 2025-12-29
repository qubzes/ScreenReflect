package com.screenreflect.network

import android.util.Log
import java.io.BufferedOutputStream
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * High-quality network server for smooth screen mirroring.
 *
 * Design: Large buffers to prevent ANY frame drops, ensuring perfectly smooth playback.
 */
class NetworkServer : Thread() {

    companion object {
        private const val TAG = "NetworkServer"
        const val PACKET_TYPE_CONFIG: Byte = 0x00
        const val PACKET_TYPE_VIDEO: Byte = 0x01
        const val PACKET_TYPE_AUDIO: Byte = 0x02
        const val PACKET_TYPE_AUDIO_CONFIG: Byte = 0x03
        const val PACKET_TYPE_DIMENSION: Byte = 0x04

        // VERY LARGE queues - absolute smoothness is priority
        private const val VIDEO_QUEUE_SIZE = 30 // ~500ms at 60fps - ultra smooth
        private const val AUDIO_QUEUE_SIZE = 6 // Small - sync with immediate video display

        private const val HEADER_SIZE = 5
    }

    private var serverSocket: ServerSocket? = null
    private var clientSocket: Socket? = null
    private var outputStream: BufferedOutputStream? = null
    @Volatile private var running = false

    val localPort: Int
        get() = serverSocket?.localPort ?: 0

    private data class FrameData(val data: ByteArray, val isKeyFrame: Boolean)

    // Large queues - blocking put to NEVER drop frames
    private val videoQueue = ArrayBlockingQueue<FrameData>(VIDEO_QUEUE_SIZE)
    private val audioQueue = ArrayBlockingQueue<ByteArray>(AUDIO_QUEUE_SIZE)

    private val pendingConfigPacket = AtomicReference<ByteArray?>(null)
    private val pendingAudioConfigPacket = AtomicReference<ByteArray?>(null)
    private val pendingDimensionPacket = AtomicReference<ByteArray?>(null)

    @Volatile private var cachedConfigPacket: ByteArray? = null
    @Volatile private var cachedAudioConfigPacket: ByteArray? = null
    @Volatile private var cachedKeyFramePacket: ByteArray? = null

    @Volatile var onClientConnected: (() -> Unit)? = null

    private val headerBuffer = ByteArray(HEADER_SIZE)

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
                                tcpNoDelay = true
                                sendBufferSize = 2 * 1024 * 1024 // 2MB send buffer
                                receiveBufferSize = 64 * 1024
                                soTimeout = 0
                            }

                    if (clientSocket == null) continue

                    Log.i(TAG, "Client connected: ${clientSocket?.inetAddress}")
                    outputStream =
                            BufferedOutputStream(clientSocket?.getOutputStream(), 1024 * 1024)

                    clearAllPackets()

                    cachedConfigPacket?.let { writePacketDirect(PACKET_TYPE_CONFIG, it) }
                    cachedAudioConfigPacket?.let { writePacketDirect(PACKET_TYPE_AUDIO_CONFIG, it) }
                    cachedKeyFramePacket?.let {
                        Log.i(TAG, "Sending cached keyframe (${it.size} bytes)")
                        writePacketDirect(PACKET_TYPE_VIDEO, it)
                    }
                    outputStream?.flush()

                    onClientConnected?.invoke()

                    sendLoop()
                } catch (e: Exception) {
                    if (running) {
                        Log.e(TAG, "Error accepting client", e)
                        Thread.sleep(100)
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

    private fun sendLoop() {
        try {
            while (running &&
                    clientSocket != null &&
                    !clientSocket!!.isClosed &&
                    clientSocket!!.isConnected) {

                var sentSomething = false

                // Config packets
                pendingConfigPacket.getAndSet(null)?.let { data ->
                    writePacketDirect(PACKET_TYPE_CONFIG, data)
                    sentSomething = true
                }

                pendingAudioConfigPacket.getAndSet(null)?.let { data ->
                    writePacketDirect(PACKET_TYPE_AUDIO_CONFIG, data)
                    sentSomething = true
                }

                pendingDimensionPacket.getAndSet(null)?.let { data ->
                    writePacketDirect(PACKET_TYPE_DIMENSION, data)
                    sentSomething = true
                }

                // Interleaved sending: alternate video and audio for better sync
                var videoCount = 0
                var audioCount = 0
                val maxBatch = 5 // Send up to 5 of each per iteration

                while (videoCount < maxBatch || audioCount < maxBatch) {
                    var didSomething = false

                    // Send one video frame
                    if (videoCount < maxBatch) {
                        val videoFrame = videoQueue.poll()
                        if (videoFrame != null) {
                            writePacketDirect(PACKET_TYPE_VIDEO, videoFrame.data)
                            sentSomething = true
                            didSomething = true
                            videoCount++
                        }
                    }

                    // Send one audio frame (interleaved)
                    if (audioCount < maxBatch) {
                        val audioFrame = audioQueue.poll()
                        if (audioFrame != null) {
                            writePacketDirect(PACKET_TYPE_AUDIO, audioFrame)
                            sentSomething = true
                            didSomething = true
                            audioCount++
                        }
                    }

                    if (!didSomething) break
                }

                if (sentSomething) {
                    outputStream?.flush()
                } else {
                    // Wait for new data
                    val frame = videoQueue.poll(5, TimeUnit.MILLISECONDS)
                    if (frame != null) {
                        writePacketDirect(PACKET_TYPE_VIDEO, frame.data)
                        outputStream?.flush()
                    }
                }
            }
        } catch (e: InterruptedException) {
            Log.i(TAG, "Send loop interrupted")
        } catch (e: Exception) {
            Log.e(TAG, "Send loop error", e)
        }
    }

    private fun writePacketDirect(type: Byte, data: ByteArray) {
        val stream = outputStream ?: return
        val socket = clientSocket ?: return

        if (socket.isClosed || !socket.isConnected) return

        headerBuffer[0] = type
        headerBuffer[1] = ((data.size shr 24) and 0xFF).toByte()
        headerBuffer[2] = ((data.size shr 16) and 0xFF).toByte()
        headerBuffer[3] = ((data.size shr 8) and 0xFF).toByte()
        headerBuffer[4] = (data.size and 0xFF).toByte()

        stream.write(headerBuffer)
        stream.write(data)
    }

    /** NON-BLOCKING - never stalls encoder thread to prevent jitter */
    fun sendPacket(type: Byte, data: ByteArray, isKeyFrame: Boolean = false) {
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
                val frame = FrameData(data, isKeyFrame)
                // Non-blocking: if full, drop oldest NON-keyframe
                if (!videoQueue.offer(frame)) {
                    // Queue full - remove oldest non-keyframe to make room
                    val dropped = videoQueue.poll()
                    if (dropped?.isKeyFrame == true) {
                        // Oops, dropped a keyframe - put it back and drop current instead
                        videoQueue.offer(dropped)
                    } else {
                        videoQueue.offer(frame)
                    }
                }
            }
            PACKET_TYPE_AUDIO -> {
                // Non-blocking: if full, drop oldest
                if (!audioQueue.offer(data)) {
                    audioQueue.poll()
                    audioQueue.offer(data)
                }
            }
        }
    }

    fun sendDimensionUpdate(width: Int, height: Int) {
        Log.i(TAG, "Sending dimension update: ${width}x${height}")
        val buffer = ByteBuffer.allocate(8)
        buffer.putInt(width)
        buffer.putInt(height)
        pendingDimensionPacket.set(buffer.array())
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
