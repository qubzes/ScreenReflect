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
        private const val BIT_RATE = 256_000 // High quality
        private const val TIMEOUT_USEC = 0L // Non-blocking
    }

    private var audioRecord: AudioRecord? = null
    private var mediaCodec: MediaCodec? = null

    @Volatile
    private var running = false

    // Real-time timestamp tracking for A/V sync
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
        val config = AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()

        val audioFormat = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
            .build()

        val minBufferSize = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_STEREO,
            AudioFormat.ENCODING_PCM_16BIT
        )

        // Reduced buffer size for lower latency (2x min instead of 4x)
        audioRecord = AudioRecord.Builder()
            .setAudioFormat(audioFormat)
            .setBufferSizeInBytes(minBufferSize * 2)
            .setAudioPlaybackCaptureConfig(config)
            .build()
    }

    private fun setupEncoder() {
        val format = MediaFormat.createAudioFormat(MIME_TYPE, SAMPLE_RATE, CHANNEL_COUNT).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
            // Low latency settings
            setInteger(MediaFormat.KEY_LATENCY, 0)
            setInteger(MediaFormat.KEY_PRIORITY, 0) // Real-time priority
        }

        mediaCodec = MediaCodec.createEncoderByType(MIME_TYPE).apply {
            configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            start()
        }
    }

    private fun encodeLoop() {
        audioRecord?.startRecording()
        running = true
        startTimeNanos = System.nanoTime()
        packetCount = 0L
        val bufferInfo = MediaCodec.BufferInfo()
        var lastPacketLog = System.currentTimeMillis()

        while (running) {
            try {
                feedInputToEncoder()
                val encoderStatus = mediaCodec?.dequeueOutputBuffer(bufferInfo, TIMEOUT_USEC) ?: continue

                when {
                    encoderStatus == MediaCodec.INFO_TRY_AGAIN_LATER -> continue
                    encoderStatus == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val newFormat = mediaCodec?.outputFormat
                        val csdBuffer = newFormat?.getByteBuffer("csd-0")
                        if (csdBuffer != null) {
                            val csd = ByteArray(csdBuffer.remaining())
                            csdBuffer.get(csd)
                            networkServer.sendPacket(NetworkServer.PACKET_TYPE_AUDIO_CONFIG, csd)
                            Log.d(TAG, "Sent audio config (CSD-0): ${csd.size} bytes")
                        } else {
                            val manualCSD = byteArrayOf(0x11.toByte(), 0x90.toByte())
                            networkServer.sendPacket(NetworkServer.PACKET_TYPE_AUDIO_CONFIG, manualCSD)
                            Log.d(TAG, "Sent fallback audio config")
                        }
                    }
                    encoderStatus >= 0 -> {
                        val encodedData = mediaCodec?.getOutputBuffer(encoderStatus)

                        if (encodedData != null && bufferInfo.size > 0) {
                            val audioData = ByteArray(bufferInfo.size)
                            encodedData.position(bufferInfo.offset)
                            encodedData.limit(bufferInfo.offset + bufferInfo.size)
                            encodedData.get(audioData)
                            networkServer.sendPacket(NetworkServer.PACKET_TYPE_AUDIO, audioData)

                            packetCount++

                            // Periodic stats logging (every 5 seconds)
                            val now = System.currentTimeMillis()
                            if (now - lastPacketLog >= 5000) {
                                val elapsedSecs = (System.nanoTime() - startTimeNanos) / 1_000_000_000.0
                                val packetsPerSec = packetCount / elapsedSecs
                                Log.d(TAG, "Audio Stats: ${String.format("%.1f", packetsPerSec)} packets/s, Packet#$packetCount, Size: ${audioData.size} bytes")
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
