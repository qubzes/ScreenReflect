package com.screenreflect.capture

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.util.Log
import android.view.Surface
import com.screenreflect.network.NetworkServer
import java.nio.ByteBuffer

/**
 * Video encoder thread that captures screen content and encodes to H.264
 * Uses MediaCodec with Surface input for efficient hardware encoding
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
        private const val MIME_TYPE = MediaFormat.MIMETYPE_VIDEO_AVC  // H.264
        private const val FRAME_RATE = 60  // 60fps for buttery smooth motion
        private const val I_FRAME_INTERVAL = -1  // Use intra-refresh instead of periodic I-frames for lower latency
        private const val TIMEOUT_USEC = 1000L  // Ultra-low timeout for instant response

        /**
         * Round dimension to nearest multiple of 16 (required for H.264 encoding)
         */
        private fun alignDimension(dimension: Int): Int {
            return (dimension / 16) * 16
        }

        /**
         * Calculate appropriate bitrate based on resolution
         * Formula: pixels_per_frame * frame_rate * bits_per_pixel * motion_factor
         * Optimized for WiFi streaming with 60fps
         */
        private fun calculateBitrate(width: Int, height: Int): Int {
            val pixels = width * height
            val bitsPerPixel = 0.12  // Balanced for smooth WiFi streaming at 60fps
            val motionFactor = 1.2   // Motion factor for fast movement
            return (pixels * FRAME_RATE * bitsPerPixel * motionFactor).toInt()
        }
    }

    // Align dimensions to multiples of 16 for H.264 encoding
    private val alignedWidth = alignDimension(width)
    private val alignedHeight = alignDimension(height)
    private val bitRate = calculateBitrate(alignedWidth, alignedHeight)

    private var mediaCodec: MediaCodec? = null
    private var virtualDisplay: android.hardware.display.VirtualDisplay? = null
    private var inputSurface: Surface? = null
    @Volatile
    private var running = false

    override fun run() {
        try {
            setupEncoder()
            encodeLoop()
        } catch (e: Exception) {
            Log.e(TAG, "Video encoder error", e)
        } finally {
            release()
        }
    }

    private fun setupEncoder() {
        Log.i(TAG, "🎬 Original screen: ${width}x${height}, aligned: ${alignedWidth}x${alignedHeight}")
        Log.i(TAG, "🎬 Setting up video encoder: ${alignedWidth}x${alignedHeight} @ ${FRAME_RATE}fps, bitrate: ${bitRate / 1_000_000f} Mbps")

        // Create video format with aligned dimensions - OPTIMIZED FOR ZERO LAG
        val format = MediaFormat.createVideoFormat(MIME_TYPE, alignedWidth, alignedHeight).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
            setInteger(MediaFormat.KEY_FRAME_RATE, FRAME_RATE)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, I_FRAME_INTERVAL)

            // ULTRA-LOW LATENCY SETTINGS
            setInteger(MediaFormat.KEY_LOW_LATENCY, 1)  // Enable low latency mode
            setInteger(MediaFormat.KEY_PRIORITY, 0)  // Real-time priority
            setInteger(MediaFormat.KEY_LATENCY, 0)  // Request lowest possible latency

            // Use CBR (Constant Bitrate) for predictable performance
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)

            // Baseline profile for fastest encoding/decoding
            setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)

            // Intra-refresh for lower latency (no periodic I-frames)
            setInteger(MediaFormat.KEY_INTRA_REFRESH_PERIOD, 10)  // Refresh every 10 frames instead of full I-frame
        }

        // Create and configure codec
        mediaCodec = MediaCodec.createEncoderByType(MIME_TYPE).apply {
            configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            inputSurface = createInputSurface()
            start()
        }

        Log.i(TAG, "✅ Video encoder configured: ${alignedWidth}x${alignedHeight} @ ${FRAME_RATE}fps, bitrate: ${bitRate / 1_000_000f} Mbps")

        // Create virtual display - must match encoder dimensions
        virtualDisplay = mediaProjection.createVirtualDisplay(
            "ScreenReflect",
            alignedWidth,
            alignedHeight,
            dpi,
            android.hardware.display.DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            inputSurface,
            null,
            null
        )

        Log.i(TAG, "✅ Virtual display created: ${alignedWidth}x${alignedHeight} @ ${dpi}dpi (${width}x${height} original, ${height - alignedHeight}px cropped)")
        running = true

        // Give encoder a moment to stabilize before requesting keyframe
        Thread.sleep(100)

        // Request immediate I-frame for faster startup
        requestKeyFrame()
        Thread.sleep(50)
        requestKeyFrame()  // Request twice to ensure we get it
        Log.i(TAG, "🚀 Requested immediate I-frames for instant startup")
    }

    private fun encodeLoop() {
        val bufferInfo = MediaCodec.BufferInfo()

        while (running) {
            try {
                val encoderStatus = mediaCodec?.dequeueOutputBuffer(bufferInfo, TIMEOUT_USEC) ?: continue

                when {
                    encoderStatus == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        // No output available yet
                    }
                    encoderStatus == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val newFormat = mediaCodec?.outputFormat
                        Log.i(TAG, "Output format changed: $newFormat")
                    }
                    encoderStatus >= 0 -> {
                        val encodedData = mediaCodec?.getOutputBuffer(encoderStatus)

                        if (encodedData != null && bufferInfo.size > 0) {
                            // Check if this is codec configuration data (SPS/PPS)
                            if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                                Log.i(TAG, "Got codec config (SPS/PPS): ${bufferInfo.size} bytes")

                                // Extract and send config packet
                                val configData = ByteArray(bufferInfo.size)
                                encodedData.position(bufferInfo.offset)
                                encodedData.limit(bufferInfo.offset + bufferInfo.size)
                                encodedData.get(configData)

                                networkServer.sendPacket(NetworkServer.PACKET_TYPE_CONFIG, configData)
                            } else {
                                // Regular video frame
                                val frameData = ByteArray(bufferInfo.size)
                                encodedData.position(bufferInfo.offset)
                                encodedData.limit(bufferInfo.offset + bufferInfo.size)
                                encodedData.get(frameData)

                                networkServer.sendPacket(NetworkServer.PACKET_TYPE_VIDEO, frameData)
                            }
                        }

                        mediaCodec?.releaseOutputBuffer(encoderStatus, false)

                        // Check for end of stream
                        if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            Log.i(TAG, "End of stream reached")
                            running = false
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error in encode loop", e)
                running = false
            }
        }
    }

    fun stopEncoding() {
        running = false
    }

    /**
     * Request an immediate keyframe (I-frame) from the encoder
     * Useful when a new client connects to get video faster
     */
    fun requestKeyFrame() {
        try {
            mediaCodec?.let { codec ->
                val params = android.os.Bundle()
                params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                codec.setParameters(params)
                Log.d(TAG, "Requested sync frame (keyframe)")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error requesting keyframe", e)
        }
    }

    private fun release() {
        Log.i(TAG, "Releasing video encoder")

        try {
            virtualDisplay?.release()
            virtualDisplay = null
        } catch (e: Exception) {
            Log.e(TAG, "Error releasing virtual display", e)
        }

        try {
            inputSurface?.release()
            inputSurface = null
        } catch (e: Exception) {
            Log.e(TAG, "Error releasing input surface", e)
        }

        try {
            mediaCodec?.stop()
            mediaCodec?.release()
            mediaCodec = null
        } catch (e: Exception) {
            Log.e(TAG, "Error releasing media codec", e)
        }
    }
}
