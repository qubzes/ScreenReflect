package com.screenreflect.capture

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.util.Log
import com.screenreflect.network.NetworkServer

/**
 * Real-time audio encoder for low-latency streaming.
 *
 * Key optimizations:
 * - Doubled audio buffer size for smoother capture
 * - ADTS framing for self-contained audio packets
 * - Non-blocking codec operations
 */
class AudioEncoder(
        private val mediaProjection: MediaProjection,
        private val networkServer: NetworkServer
) : Thread() {

    companion object {
        private const val TAG = "AudioEncoder"
        private const val MIME_TYPE = MediaFormat.MIMETYPE_AUDIO_AAC
        private const val SAMPLE_RATE = 48000
        private const val CHANNEL_COUNT = 2
        private const val BIT_RATE = 128_000
        private const val TIMEOUT_USEC = 0L

        // ADTS constants
        private const val ADTS_HEADER_SIZE = 7
        private const val SAMPLE_RATE_INDEX = 3 // 48000Hz
        private const val CHANNEL_CONFIG = 2 // stereo
    }

    private var audioRecord: AudioRecord? = null
    private var mediaCodec: MediaCodec? = null

    @Volatile private var running = false

    private var startTimeNanos: Long = 0L
    private var packetCount: Long = 0L

    // Pre-allocated ADTS header buffer
    private val adtsHeader = ByteArray(ADTS_HEADER_SIZE)

    override fun run() {
        try {
            setupAudioCapture()
            setupEncoder()
            encodeLoop()
        } catch (e: Exception) {
            Log.e(TAG, "Audio error", e)
        } finally {
            release()
        }
    }

    private fun setupAudioCapture() {
        val config =
                AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
                        .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                        .addMatchingUsage(AudioAttributes.USAGE_GAME)
                        .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                        .build()

        val audioFormat =
                AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
                        .build()

        val minBufferSize =
                AudioRecord.getMinBufferSize(
                        SAMPLE_RATE,
                        AudioFormat.CHANNEL_IN_STEREO,
                        AudioFormat.ENCODING_PCM_16BIT
                )

        // Use 2x minimum buffer for smoother capture
        audioRecord =
                AudioRecord.Builder()
                        .setAudioFormat(audioFormat)
                        .setBufferSizeInBytes(minBufferSize * 2)
                        .setAudioPlaybackCaptureConfig(config)
                        .build()
    }

    private fun setupEncoder() {
        val format =
                MediaFormat.createAudioFormat(MIME_TYPE, SAMPLE_RATE, CHANNEL_COUNT).apply {
                    setInteger(
                            MediaFormat.KEY_AAC_PROFILE,
                            MediaCodecInfo.CodecProfileLevel.AACObjectLC
                    )
                    setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
                    setInteger(MediaFormat.KEY_LATENCY, 0)
                    setInteger(MediaFormat.KEY_PRIORITY, 0)
                }

        mediaCodec =
                MediaCodec.createEncoderByType(MIME_TYPE).apply {
                    configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                    start()
                }
    }

    /** Generate ADTS header for AAC frame. Reuses pre-allocated buffer to avoid allocations. */
    private fun fillAdtsHeader(frameLength: Int) {
        val packetLen = frameLength + ADTS_HEADER_SIZE

        // ADTS header structure (7 bytes)
        adtsHeader[0] = 0xFF.toByte() // Syncword high
        adtsHeader[1] = 0xF1.toByte() // Syncword low + MPEG-4 + no CRC
        adtsHeader[2] =
                ((0 shl 6) or (SAMPLE_RATE_INDEX shl 2) or (0 shl 1) or (CHANNEL_CONFIG shr 2))
                        .toByte()
        adtsHeader[3] =
                (((CHANNEL_CONFIG and 0x03) shl 6) or ((packetLen shr 11) and 0x03)).toByte()
        adtsHeader[4] = ((packetLen shr 3) and 0xFF).toByte()
        adtsHeader[5] = (((packetLen and 0x07) shl 5) or 0x1F).toByte()
        adtsHeader[6] = 0xFC.toByte()
    }

    private fun encodeLoop() {
        audioRecord?.startRecording()
        running = true
        startTimeNanos = System.nanoTime()
        packetCount = 0L
        val bufferInfo = MediaCodec.BufferInfo()
        var lastPacketLog = System.currentTimeMillis()
        var consecutiveEmptyPolls = 0

        while (running) {
            try {
                // Feed input data
                feedInputToEncoder()

                val encoderStatus =
                        mediaCodec?.dequeueOutputBuffer(bufferInfo, TIMEOUT_USEC) ?: continue

                when {
                    encoderStatus == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        consecutiveEmptyPolls++
                        if (consecutiveEmptyPolls > 50) {
                            Thread.yield()
                        }
                    }
                    encoderStatus == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        // Send config marker for ADTS mode
                        val csd = byteArrayOf(0x11.toByte(), 0x90.toByte()) // AAC-LC 48kHz stereo
                        networkServer.sendPacket(NetworkServer.PACKET_TYPE_AUDIO_CONFIG, csd)
                        Log.d(TAG, "Audio format configured (ADTS mode)")
                    }
                    encoderStatus >= 0 -> {
                        consecutiveEmptyPolls = 0

                        val encodedData = mediaCodec?.getOutputBuffer(encoderStatus)

                        if (encodedData != null && bufferInfo.size > 0) {
                            // Get raw AAC data
                            val rawAacData = ByteArray(bufferInfo.size)
                            encodedData.position(bufferInfo.offset)
                            encodedData.limit(bufferInfo.offset + bufferInfo.size)
                            encodedData.get(rawAacData)

                            // Create ADTS frame
                            fillAdtsHeader(rawAacData.size)
                            val adtsFrame = ByteArray(ADTS_HEADER_SIZE + rawAacData.size)
                            System.arraycopy(adtsHeader, 0, adtsFrame, 0, ADTS_HEADER_SIZE)
                            System.arraycopy(
                                    rawAacData,
                                    0,
                                    adtsFrame,
                                    ADTS_HEADER_SIZE,
                                    rawAacData.size
                            )

                            // Send ADTS frame
                            networkServer.sendPacket(NetworkServer.PACKET_TYPE_AUDIO, adtsFrame)

                            packetCount++

                            val now = System.currentTimeMillis()
                            if (now - lastPacketLog >= 5000) {
                                val elapsedSecs =
                                        (System.nanoTime() - startTimeNanos) / 1_000_000_000.0
                                val packetsPerSec = packetCount / elapsedSecs
                                Log.d(
                                        TAG,
                                        "Audio Stats: ${String.format("%.1f", packetsPerSec)} packets/s, Packet#$packetCount"
                                )
                                lastPacketLog = now
                            }
                        }

                        mediaCodec?.releaseOutputBuffer(encoderStatus, false)

                        if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            Log.d(TAG, "End of audio stream")
                            running = false
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Audio encode error", e)
                running = false
            }
        }
    }

    private fun feedInputToEncoder() {
        val inputBufferIndex = mediaCodec?.dequeueInputBuffer(TIMEOUT_USEC) ?: return
        if (inputBufferIndex >= 0) {
            val inputBuffer = mediaCodec?.getInputBuffer(inputBufferIndex) ?: return
            val readBytes = audioRecord?.read(inputBuffer, inputBuffer.capacity()) ?: 0

            if (readBytes > 0) {
                mediaCodec?.queueInputBuffer(
                        inputBufferIndex,
                        0,
                        readBytes,
                        System.nanoTime() / 1000,
                        0
                )
            }
        }
    }

    fun stopEncoding() {
        running = false
    }

    private fun release() {
        try {
            audioRecord?.stop()
            audioRecord?.release()
            mediaCodec?.stop()
            mediaCodec?.release()
        } catch (e: Exception) {
            Log.e(TAG, "Release error", e)
        }
    }
}
