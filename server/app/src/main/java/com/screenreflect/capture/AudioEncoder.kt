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
        // Sample rate index for ADTS: 48000Hz = index 3
        private const val SAMPLE_RATE_INDEX = 3
        // Channel config: 2 channels = 2
        private const val CHANNEL_CONFIG = 2
    }

    private var audioRecord: AudioRecord? = null
    private var mediaCodec: MediaCodec? = null

    @Volatile private var running = false

    private var startTimeNanos: Long = 0L
    private var packetCount: Long = 0L

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

        audioRecord =
                AudioRecord.Builder()
                        .setAudioFormat(audioFormat)
                        .setBufferSizeInBytes(minBufferSize)
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

    /**
     * Generate ADTS header for AAC frame. ADTS allows the decoder to sync and decode each frame
     * independently.
     */
    private fun createAdtsHeader(frameLength: Int): ByteArray {
        val header = ByteArray(ADTS_HEADER_SIZE)
        val packetLen = frameLength + ADTS_HEADER_SIZE

        // ADTS header structure (7 bytes):
        // Syncword: 0xFFF (12 bits)
        // ID: 0 = MPEG-4, 1 = MPEG-2 (1 bit)
        // Layer: 00 (2 bits)
        // Protection absent: 1 = no CRC (1 bit)
        // Profile: AAC-LC = 1 (2 bits, profile - 1)
        // Sampling frequency index (4 bits)
        // Private bit: 0 (1 bit)
        // Channel configuration (3 bits)
        // Original/copy: 0 (1 bit)
        // Home: 0 (1 bit)
        // Copyright ID bit: 0 (1 bit)
        // Copyright ID start: 0 (1 bit)
        // Frame length (13 bits)
        // Buffer fullness: 0x7FF (11 bits)
        // Number of AAC frames - 1: 0 (2 bits)

        // Byte 0: 0xFF (syncword high)
        header[0] = 0xFF.toByte()

        // Byte 1: 0xF1 (syncword low + MPEG-4 + Layer 00 + no CRC)
        header[1] = 0xF1.toByte()

        // Byte 2: profile (AAC-LC=1, so 0) + sampling freq index + private bit + channel config
        // high
        // AAC-LC profile = 1, stored as (profile - 1) = 0
        // Sampling frequency index for 48000Hz = 3
        // Channel config = 2 (stereo)
        header[2] =
                ((0 shl 6) or (SAMPLE_RATE_INDEX shl 2) or (0 shl 1) or (CHANNEL_CONFIG shr 2))
                        .toByte()

        // Byte 3: channel config low + original + home + copyright + copyright start + frame length
        // high
        header[3] = (((CHANNEL_CONFIG and 0x03) shl 6) or ((packetLen shr 11) and 0x03)).toByte()

        // Byte 4: frame length middle
        header[4] = ((packetLen shr 3) and 0xFF).toByte()

        // Byte 5: frame length low + buffer fullness high
        header[5] = (((packetLen and 0x07) shl 5) or 0x1F).toByte()

        // Byte 6: buffer fullness low + number of frames - 1
        header[6] = 0xFC.toByte()

        return header
    }

    private fun encodeLoop() {
        audioRecord?.startRecording()
        running = true
        startTimeNanos = System.nanoTime()
        packetCount = 0L
        val bufferInfo = MediaCodec.BufferInfo()
        var lastPacketLog = System.currentTimeMillis()
        var configSent = false

        while (running) {
            try {
                feedInputToEncoder()
                val encoderStatus =
                        mediaCodec?.dequeueOutputBuffer(bufferInfo, TIMEOUT_USEC) ?: continue

                when {
                    encoderStatus == MediaCodec.INFO_TRY_AGAIN_LATER -> continue
                    encoderStatus == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        // For ADTS, we don't need to send CSD separately
                        // The ADTS header contains enough info for decoder to initialize
                        // But we still send a marker so the client knows audio is configured
                        val csd = byteArrayOf(0x11.toByte(), 0x90.toByte()) // AAC-LC 48kHz stereo
                        networkServer.sendPacket(NetworkServer.PACKET_TYPE_AUDIO_CONFIG, csd)
                        configSent = true
                        Log.d(TAG, "Audio format configured (ADTS mode)")
                    }
                    encoderStatus >= 0 -> {
                        val encodedData = mediaCodec?.getOutputBuffer(encoderStatus)

                        if (encodedData != null && bufferInfo.size > 0) {
                            // Get raw AAC data
                            val rawAacData = ByteArray(bufferInfo.size)
                            encodedData.position(bufferInfo.offset)
                            encodedData.limit(bufferInfo.offset + bufferInfo.size)
                            encodedData.get(rawAacData)

                            // Create ADTS header and combine with AAC data
                            val adtsHeader = createAdtsHeader(rawAacData.size)
                            val adtsFrame = ByteArray(adtsHeader.size + rawAacData.size)
                            System.arraycopy(adtsHeader, 0, adtsFrame, 0, adtsHeader.size)
                            System.arraycopy(
                                    rawAacData,
                                    0,
                                    adtsFrame,
                                    adtsHeader.size,
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
                                        "Audio Stats: ${String.format("%.1f", packetsPerSec)} packets/s, Packet#$packetCount, ADTS frame: ${adtsFrame.size} bytes"
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
