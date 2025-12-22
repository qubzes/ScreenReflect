package com.screenreflect.capture

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.util.Log
import android.view.Surface
import com.screenreflect.network.NetworkServer

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
        private const val I_FRAME_INTERVAL = 2 // I-frame every 2 seconds for better error recovery
        private const val TIMEOUT_USEC = 0L // Non-blocking for maximum throughput

        // Round UP to nearest multiple of 16 to avoid black bars
        // Example: 1079 -> 1088 (not 1072)
        private fun alignDimension(dimension: Int): Int {
            val remainder = dimension % 16
            return if (remainder == 0) dimension else dimension + (16 - remainder)
        }

        private fun calculateBitrate(width: Int, height: Int): Int {
            val pixels = width * height
            // Optimized bitrate: 0.07 bits per pixel (balanced quality/bandwidth)
            // For 1920x1080@60fps: ~8.6 Mbps (vs previous ~15 Mbps)
            return (pixels * FRAME_RATE * 0.07 * 1.0).toInt()
        }
    }

    private var alignedWidth = alignDimension(width)
    private var alignedHeight = alignDimension(height)
    private val bitRate = calculateBitrate(alignedWidth, alignedHeight)

    // Public accessors for actual encoded dimensions
    val encodedWidth: Int
        get() = alignedWidth
    val encodedHeight: Int
        get() = alignedHeight

    private var mediaCodec: MediaCodec? = null
    private var virtualDisplay: android.hardware.display.VirtualDisplay? = null
    private var inputSurface: Surface? = null

    @Volatile private var running = false

    // Real-time timestamp tracking for A/V sync
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
                    setInteger(
                            MediaFormat.KEY_BIT_RATE,
                            10_000_000
                    ) // 10 Mbps fixed for high quality
                    setInteger(MediaFormat.KEY_FRAME_RATE, FRAME_RATE)
                    setInteger(
                            MediaFormat.KEY_I_FRAME_INTERVAL,
                            1
                    ) // I-frame every 1 second for faster recovery
                    setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                    setInteger(MediaFormat.KEY_PRIORITY, 0)
                    setInteger(MediaFormat.KEY_LATENCY, 0)
                    setInteger(
                            MediaFormat.KEY_BITRATE_MODE,
                            MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR
                    )
                    // Use Main profile for better compression and quality
                    setInteger(
                            MediaFormat.KEY_PROFILE,
                            MediaCodecInfo.CodecProfileLevel.AVCProfileMain
                    )
                    setInteger(
                            MediaFormat.KEY_LEVEL,
                            MediaCodecInfo.CodecProfileLevel.AVCLevel42
                    ) // Level 4.2 for 1080p60
                    // Intra refresh for error resilience without full I-frames
                    // setInteger(MediaFormat.KEY_INTRA_REFRESH_PERIOD, 10) // Disabled: relying on
                    // frequent I-frames
                    // Quality and complexity hints
                    setInteger(
                            MediaFormat.KEY_COMPLEXITY,
                            MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR
                    )
                    setInteger(
                            MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER,
                            100_000
                    ) // 100ms max to prevent decoder stall
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

        // Request initial keyframe after a brief stabilization period
        Thread.sleep(100)
        requestKeyFrame()
    }

    private fun encodeLoop() {
        val bufferInfo = MediaCodec.BufferInfo()
        var lastFrameLog = System.currentTimeMillis()

        while (running) {
            try {
                val encoderStatus =
                        mediaCodec?.dequeueOutputBuffer(bufferInfo, TIMEOUT_USEC) ?: continue

                when {
                    encoderStatus == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        // Non-blocking mode: yield to prevent tight loop
                        Thread.yield()
                        continue
                    }
                    encoderStatus == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        Log.d(TAG, "Encoder output format changed")
                        continue
                    }
                    encoderStatus >= 0 -> {
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
        // Interrupt thread to break out of encode loop if in yield/sleep
        interrupt()
    }

    /**
     * Notify about dimension change without recreating encoder The VirtualDisplay will
     * automatically adapt to orientation changes
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
