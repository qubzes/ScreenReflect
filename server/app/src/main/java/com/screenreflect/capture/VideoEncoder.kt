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
        private const val I_FRAME_INTERVAL = -1
        private const val TIMEOUT_USEC = 1000L

        private fun alignDimension(dimension: Int): Int = (dimension / 16) * 16

        private fun calculateBitrate(width: Int, height: Int): Int {
            val pixels = width * height
            return (pixels * FRAME_RATE * 0.12 * 1.2).toInt()
        }
    }

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
            Log.e(TAG, "Encoder error", e)
        } finally {
            release()
        }
    }

    private fun setupEncoder() {
        val format = MediaFormat.createVideoFormat(MIME_TYPE, alignedWidth, alignedHeight).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
            setInteger(MediaFormat.KEY_FRAME_RATE, FRAME_RATE)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, I_FRAME_INTERVAL)
            setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            setInteger(MediaFormat.KEY_LATENCY, 0)
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
            setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
            setInteger(MediaFormat.KEY_INTRA_REFRESH_PERIOD, 10)
        }

        mediaCodec = MediaCodec.createEncoderByType(MIME_TYPE).apply {
            configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            inputSurface = createInputSurface()
            start()
        }

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

        running = true
        Thread.sleep(100)
        requestKeyFrame()
        Thread.sleep(50)
        requestKeyFrame()
    }

    private fun encodeLoop() {
        val bufferInfo = MediaCodec.BufferInfo()

        while (running) {
            try {
                val encoderStatus = mediaCodec?.dequeueOutputBuffer(bufferInfo, TIMEOUT_USEC) ?: continue

                when {
                    encoderStatus == MediaCodec.INFO_TRY_AGAIN_LATER -> continue
                    encoderStatus == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> continue
                    encoderStatus >= 0 -> {
                        val encodedData = mediaCodec?.getOutputBuffer(encoderStatus)

                        if (encodedData != null && bufferInfo.size > 0) {
                            if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                                val configData = ByteArray(bufferInfo.size)
                                encodedData.position(bufferInfo.offset)
                                encodedData.limit(bufferInfo.offset + bufferInfo.size)
                                encodedData.get(configData)
                                networkServer.sendPacket(NetworkServer.PACKET_TYPE_CONFIG, configData)
                            } else {
                                val frameData = ByteArray(bufferInfo.size)
                                encodedData.position(bufferInfo.offset)
                                encodedData.limit(bufferInfo.offset + bufferInfo.size)
                                encodedData.get(frameData)
                                networkServer.sendPacket(NetworkServer.PACKET_TYPE_VIDEO, frameData)
                            }
                        }

                        mediaCodec?.releaseOutputBuffer(encoderStatus, false)

                        if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
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
        running = false
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
