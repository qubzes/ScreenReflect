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
    private var cachedKeyFramePacket: ByteArray? = null

    @Volatile
    var onClientConnected: (() -> Unit)? = null

    data class Packet(val type: Byte, val data: ByteArray)

    override fun run() {
        try {
            serverSocket = ServerSocket(0).apply {
                reuseAddress = true
            }

            running = true
            
            // Main server loop - keeps accepting new clients
            while (running && !isInterrupted) {
                try {
                    Log.i(TAG, "Waiting for client connection...")
                    clientSocket = serverSocket?.accept()?.apply {
                        keepAlive = true
                        tcpNoDelay = true // Disable Nagle's algorithm for low latency
                        sendBufferSize = 512 * 1024 // Increased from 256KB to 512KB for smoother streaming
                        receiveBufferSize = 64 * 1024 // Optimize receive buffer
                        soTimeout = 0 // No timeout for blocking reads
                    }
                    
                    if (clientSocket == null) continue

                    Log.i(TAG, "Client connected: ${clientSocket?.inetAddress}")
                    outputStream = clientSocket?.getOutputStream()

                    // Clear any old packets from previous session
                    packetQueue.clear()

                    // Send cached config packets immediately
                    cachedConfigPacket?.let { sendPacketInternal(PACKET_TYPE_CONFIG, it) }
                    cachedAudioConfigPacket?.let { sendPacketInternal(PACKET_TYPE_AUDIO_CONFIG, it) }
                    
                    // Send last keyframe immediately so client has something to show
                    cachedKeyFramePacket?.let { 
                        Log.i(TAG, "Sending cached keyframe to new client (${it.size} bytes)")
                        sendPacketInternal(PACKET_TYPE_VIDEO, it) 
                    }

                    onClientConnected?.invoke()

                    // Inner loop - serves the connected client
                    // We run this directly on the server thread instead of spawning a new one
                    // because we only handle one client at a time anyway.
                    try {
                        while (running && clientSocket != null && !clientSocket!!.isClosed && clientSocket!!.isConnected) {
                            val packet = packetQueue.take() // Blocks until packet available
                            sendPacketInternal(packet.type, packet.data)
                        }
                    } catch (e: InterruptedException) {
                        Log.i(TAG, "Server thread interrupted")
                        running = false
                        break
                    } catch (e: Exception) {
                        Log.e(TAG, "Client connection error", e)
                    } finally {
                        Log.i(TAG, "Client disconnected, cleaning up...")
                        cleanupClient()
                    }
                    
                } catch (e: Exception) {
                    if (running) {
                        Log.e(TAG, "Error accepting client", e)
                        // Small delay to prevent tight loop on persistent error
                        Thread.sleep(1000)
                    }
                }
            }

        } catch (e: Exception) {
            Log.e(TAG, "Server fatal error", e)
        } finally {
            close()
        }
    }

    fun sendPacket(type: Byte, data: ByteArray, isKeyFrame: Boolean = false) {
        if (type == PACKET_TYPE_CONFIG) {
            cachedConfigPacket = data
        }

        if (type == PACKET_TYPE_AUDIO_CONFIG) {
            cachedAudioConfigPacket = data
        }
        
        if (isKeyFrame && type == PACKET_TYPE_VIDEO) {
            cachedKeyFramePacket = data
        }

        if (running && outputStream != null) {
            // Config packets always get priority
            if (type == PACKET_TYPE_CONFIG || type == PACKET_TYPE_AUDIO_CONFIG) {
                packetQueue.offer(Packet(type, data))
                return
            }

            // Try to add packet to queue; if queue is full, log warning but don't drop
            if (!packetQueue.offer(Packet(type, data))) {
                // Only log occasionally or if critical to avoid spam
                // val packetTypeName = when (type) {
                //     PACKET_TYPE_VIDEO -> "VIDEO"
                //     PACKET_TYPE_AUDIO -> "AUDIO"
                //     else -> "UNKNOWN"
                // }
                // Log.w(TAG, "Queue full! Dropping $packetTypeName packet")
            }
        }
    }

    @Synchronized
    private fun sendPacketInternal(type: Byte, data: ByteArray) {
        try {
            val stream = outputStream ?: throw Exception("No output stream")
            val socket = clientSocket

            if (socket == null || socket.isClosed || !socket.isConnected) {
                throw Exception("Socket closed")
            }

            stream.write(type.toInt())

            val lengthBuffer = ByteBuffer.allocate(4)
            lengthBuffer.putInt(data.size)
            stream.write(lengthBuffer.array())

            stream.write(data)
            // stream.flush() // Flush might not be strictly necessary after every write if buffer is large enough, but good for latency

        } catch (e: Exception) {
            // Propagate exception to break the inner loop
            throw e
        }
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
        interrupt() // Interrupt the thread to break out of packetQueue.take()
        
        try {
            serverSocket?.close()
            serverSocket = null
        } catch (e: Exception) {
            Log.e(TAG, "Error closing server socket", e)
        }
        
        cleanupClient()
        packetQueue.clear()
    }
}
