package com.screenreflect.capture

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.util.Log
import android.view.Surface
import com.screenreflect.network.NetworkServer

/**
 * Real-time video encoder optimized for low-latency streaming.
 *
 * Key optimizations:
 * - Hardware-accelerated H.264 encoding
 * - CBR mode for consistent bandwidth
 * - Low-latency flags enabled
 * - I-frame every 2 seconds (balance between recovery and bandwidth)
 * - Non-blocking output buffer dequeue
 */
class VideoEncoder(
        private val mediaProjection: MediaProjection,
        private val networkServer: NetworkServer,
        private val width: Int = 1920,
        private val height: Int = 1080,
        private val dpi: Int = 320
) : Thread() {

    companion object {
        private const val TAG = "VideoEncoder"
        private const val MIME_TYPE = MediaFormat.MIMETYPE_VIDEO_AVC
        private const val FRAME_RATE = 60
        private const val I_FRAME_INTERVAL = 1 // I-frame every 1 second for fast motion recovery
        private const val TIMEOUT_USEC = 0L // Non-blocking for maximum throughput

        // Round UP to nearest multiple of 16 to avoid black bars
        private fun alignDimension(dimension: Int): Int {
            val remainder = dimension % 16
            return if (remainder == 0) dimension else dimension + (16 - remainder)
        }
    }

    private var alignedWidth = alignDimension(width)
    private var alignedHeight = alignDimension(height)

    // Public accessors for actual encoded dimensions
    val encodedWidth: Int
        get() = alignedWidth
    val encodedHeight: Int
        get() = alignedHeight

    private var mediaCodec: MediaCodec? = null
    private var virtualDisplay: android.hardware.display.VirtualDisplay? = null
    private var inputSurface: Surface? = null

    @Volatile private var running = false

    // Stats tracking
    private var startTimeNanos: Long = 0L
    private var frameCount: Long = 0L

    override fun run() {
        try {
            setupEncoder()
            encodeLoop()
        } catch (e: Exception) {
            Log.e(TAG, "Encoder error", e)
        } finally {
            release()
        }
    }

    private fun setupEncoder() {
        val format =
                MediaFormat.createVideoFormat(MIME_TYPE, alignedWidth, alignedHeight).apply {
                    setInteger(
                            MediaFormat.KEY_COLOR_FORMAT,
                            MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface
                    )
                    // 20 Mbps for high quality fast-motion content
                    setInteger(MediaFormat.KEY_BIT_RATE, 20_000_000)
                    setInteger(MediaFormat.KEY_FRAME_RATE, FRAME_RATE)
                    // I-frame every 1 second - fast recovery for scrolling
                    setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, I_FRAME_INTERVAL)

                    // Low-latency encoding settings
                    setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                    setInteger(MediaFormat.KEY_PRIORITY, 0) // Real-time priority
                    setInteger(MediaFormat.KEY_LATENCY, 0)

                    // CBR for consistent streaming
                    setInteger(
                            MediaFormat.KEY_BITRATE_MODE,
                            MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR
                    )

                    // Use Main profile for good compression
                    setInteger(
                            MediaFormat.KEY_PROFILE,
                            MediaCodecInfo.CodecProfileLevel.AVCProfileMain
                    )
                    setInteger(
                            MediaFormat.KEY_LEVEL,
                            MediaCodecInfo.CodecProfileLevel.AVCLevel42
                    ) // Level 4.2 for 1080p60
                }

        mediaCodec =
                MediaCodec.createEncoderByType(MIME_TYPE).apply {
                    configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                    inputSurface = createInputSurface()
                    start()
                }

        virtualDisplay =
                mediaProjection.createVirtualDisplay(
                        "ScreenReflect",
                        alignedWidth,
                        alignedHeight,
                        dpi,
                        android.hardware.display.DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                        inputSurface,
                        null,
                        null
                )

        running = true
        startTimeNanos = System.nanoTime()
        frameCount = 0L

        // Request initial keyframe after brief stabilization
        Thread.sleep(50)
        requestKeyFrame()
    }

    private fun encodeLoop() {
        val bufferInfo = MediaCodec.BufferInfo()
        var lastFrameLog = System.currentTimeMillis()
        var consecutiveEmptyPolls = 0

        while (running) {
            try {
                val encoderStatus =
                        mediaCodec?.dequeueOutputBuffer(bufferInfo, TIMEOUT_USEC) ?: continue

                when {
                    encoderStatus == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        // Non-blocking: increment counter for adaptive wait
                        consecutiveEmptyPolls++
                        if (consecutiveEmptyPolls > 100) {
                            // After 100 empty polls, yield to prevent CPU spin
                            Thread.yield()
                        }
                        continue
                    }
                    encoderStatus == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        Log.d(TAG, "Encoder output format changed")
                        continue
                    }
                    encoderStatus >= 0 -> {
                        consecutiveEmptyPolls = 0 // Reset on successful dequeue

                        val encodedData = mediaCodec?.getOutputBuffer(encoderStatus)

                        if (encodedData != null && bufferInfo.size > 0) {
                            if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                                // SPS/PPS config data
                                val configData = ByteArray(bufferInfo.size)
                                encodedData.position(bufferInfo.offset)
                                encodedData.limit(bufferInfo.offset + bufferInfo.size)
                                encodedData.get(configData)
                                networkServer.sendPacket(
                                        NetworkServer.PACKET_TYPE_CONFIG,
                                        configData
                                )
                                Log.d(TAG, "Sent config packet: ${bufferInfo.size} bytes")
                            } else {
                                // Regular video frame
                                val frameData = ByteArray(bufferInfo.size)
                                encodedData.position(bufferInfo.offset)
                                encodedData.limit(bufferInfo.offset + bufferInfo.size)
                                encodedData.get(frameData)

                                val isKeyFrame =
                                        (bufferInfo.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                                networkServer.sendPacket(
                                        NetworkServer.PACKET_TYPE_VIDEO,
                                        frameData,
                                        isKeyFrame
                                )

                                frameCount++

                                // Periodic stats logging (every 5 seconds)
                                val now = System.currentTimeMillis()
                                if (now - lastFrameLog >= 5000) {
                                    val elapsedSecs =
                                            (System.nanoTime() - startTimeNanos) / 1_000_000_000.0
                                    val actualFps = frameCount / elapsedSecs
                                    Log.d(
                                            TAG,
                                            "Stats: ${String.format("%.1f", actualFps)} FPS, Frame#$frameCount, Size: ${frameData.size} bytes, KeyFrame: $isKeyFrame"
                                    )
                                    lastFrameLog = now
                                }
                            }
                        }

                        mediaCodec?.releaseOutputBuffer(encoderStatus, false)

                        if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            Log.d(TAG, "End of stream")
                            running = false
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Encode error", e)
                running = false
            }
        }
    }

    fun stopEncoding() {
        Log.d(TAG, "stopEncoding() called")
        running = false
        interrupt()
    }

    /**
     * Notify about dimension change without recreating encoder. The VirtualDisplay will
     * automatically adapt to orientation changes.
     */
    fun notifyDimensionChange(newWidth: Int, newHeight: Int) {
        val alignedW = alignDimension(newWidth)
        val alignedH = alignDimension(newHeight)

        // Update internal dimensions for reporting
        alignedWidth = alignedW
        alignedHeight = alignedH

        // Request keyframe for clean transition
        requestKeyFrame()

        Log.i(TAG, "✅ Dimension change notified: ${alignedW}x${alignedH}")
    }

    fun requestKeyFrame() {
        try {
            mediaCodec?.let {
                val params = android.os.Bundle()
                params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                it.setParameters(params)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Keyframe error", e)
        }
    }

    private fun release() {
        try {
            virtualDisplay?.release()
            inputSurface?.release()
            mediaCodec?.stop()
            mediaCodec?.release()
        } catch (e: Exception) {
            Log.e(TAG, "Release error", e)
        }
    }
}
