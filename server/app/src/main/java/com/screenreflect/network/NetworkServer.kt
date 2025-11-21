package com.screenreflect.network

import android.util.Log
import java.io.OutputStream
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.BlockingQueue
import java.util.concurrent.LinkedBlockingQueue

class NetworkServer : Thread() {

    companion object {
        private const val TAG = "NetworkServer"
        const val PACKET_TYPE_CONFIG: Byte = 0x00
        const val PACKET_TYPE_VIDEO: Byte = 0x01
        const val PACKET_TYPE_AUDIO: Byte = 0x02
        const val PACKET_TYPE_AUDIO_CONFIG: Byte = 0x03
    }

    private var serverSocket: ServerSocket? = null
    private var clientSocket: Socket? = null
    private var outputStream: OutputStream? = null
    private var running = false

    val localPort: Int
        get() = serverSocket?.localPort ?: 0

    // Increased queue size from 30 to 150 to prevent frame drops at 60fps
    // At 60fps, this allows ~2.5 seconds of buffering
    private val packetQueue: BlockingQueue<Packet> = LinkedBlockingQueue(150)

    @Volatile
    private var cachedConfigPacket: ByteArray? = null

    @Volatile
    private var cachedAudioConfigPacket: ByteArray? = null

    @Volatile
    var onClientConnected: (() -> Unit)? = null

    data class Packet(val type: Byte, val data: ByteArray)

    override fun run() {
        try {
            serverSocket = ServerSocket(0).apply {
                reuseAddress = true
            }

            running = true

            clientSocket = serverSocket?.accept()?.apply {
                keepAlive = true
                tcpNoDelay = true // Disable Nagle's algorithm for low latency
                sendBufferSize = 512 * 1024 // Increased from 256KB to 512KB for smoother streaming
                receiveBufferSize = 64 * 1024 // Optimize receive buffer
                soTimeout = 0 // No timeout for blocking reads
            }

            outputStream = clientSocket?.getOutputStream()

            cachedConfigPacket?.let { sendPacketInternal(PACKET_TYPE_CONFIG, it) }
            cachedAudioConfigPacket?.let { sendPacketInternal(PACKET_TYPE_AUDIO_CONFIG, it) }

            onClientConnected?.invoke()

            Thread {
                try {
                    while (running && outputStream != null) {
                        val packet = packetQueue.take()
                        sendPacketInternal(packet.type, packet.data)
                    }
                } catch (e: InterruptedException) {
                    // Thread interrupted
                } catch (e: Exception) {
                    Log.e(TAG, "Sender error", e)
                }
            }.start()

            while (running) {
                Thread.sleep(1000)
            }

        } catch (e: Exception) {
            Log.e(TAG, "Server error", e)
        } finally {
            close()
        }
    }

    fun sendPacket(type: Byte, data: ByteArray) {
        if (type == PACKET_TYPE_CONFIG) {
            cachedConfigPacket = data
        }

        if (type == PACKET_TYPE_AUDIO_CONFIG) {
            cachedAudioConfigPacket = data
        }

        if (running && outputStream != null) {
            // Config packets always get priority
            if (type == PACKET_TYPE_CONFIG || type == PACKET_TYPE_AUDIO_CONFIG) {
                packetQueue.offer(Packet(type, data))
                return
            }

            // Try to add packet to queue; if queue is full, log warning but don't drop
            if (!packetQueue.offer(Packet(type, data))) {
                val packetTypeName = when (type) {
                    PACKET_TYPE_VIDEO -> "VIDEO"
                    PACKET_TYPE_AUDIO -> "AUDIO"
                    else -> "UNKNOWN"
                }
                Log.w(TAG, "Queue full! Dropping $packetTypeName packet (${data.size} bytes). Consider increasing queue size or reducing encoder output.")
            }
        }
    }

    @Synchronized
    private fun sendPacketInternal(type: Byte, data: ByteArray) {
        try {
            val stream = outputStream ?: return
            val socket = clientSocket

            if (socket == null || socket.isClosed || !socket.isConnected) {
                running = false
                return
            }

            stream.write(type.toInt())

            val lengthBuffer = ByteBuffer.allocate(4)
            lengthBuffer.putInt(data.size)
            stream.write(lengthBuffer.array())

            stream.write(data)
            stream.flush()

        } catch (e: java.net.SocketException) {
            running = false
        } catch (e: Exception) {
            Log.e(TAG, "Send error", e)
            running = false
        }
    }

    fun close() {
        running = false
        try {
            outputStream?.close()
            clientSocket?.close()
            serverSocket?.close()
        } catch (e: Exception) {
            Log.e(TAG, "Close error", e)
        }
        packetQueue.clear()
    }
}
