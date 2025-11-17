package com.screenreflect.capture

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.util.Log
import com.screenreflect.network.NetworkServer

/**
 * Audio encoder thread that captures internal audio and encodes to AAC
 * Uses AudioPlaybackCapture API to capture app audio
 */
class AudioEncoder(
    private val mediaProjection: MediaProjection,
    private val networkServer: NetworkServer
) : Thread() {

    companion object {
        private const val TAG = "AudioEncoder"
        private const val MIME_TYPE = MediaFormat.MIMETYPE_AUDIO_AAC
        private const val SAMPLE_RATE = 48000
        private const val CHANNEL_COUNT = 2  // Stereo
        private const val BIT_RATE = 128_000
        private const val TIMEOUT_USEC = 10000L
    }

    private var audioRecord: AudioRecord? = null
    private var mediaCodec: MediaCodec? = null
    @Volatile
    private var running = false

    override fun run() {
        try {
            setupAudioCapture()
            setupEncoder()
            encodeLoop()
        } catch (e: Exception) {
            Log.e(TAG, "Audio encoder error", e)
        } finally {
            release()
        }
    }

    private fun setupAudioCapture() {
        try {
            // Build audio playback capture configuration
            val config = AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .build()

            // Create audio format
            val audioFormat = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(SAMPLE_RATE)
                .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
                .build()

            // Calculate buffer size
            val minBufferSize = AudioRecord.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_STEREO,
                AudioFormat.ENCODING_PCM_16BIT
            )

            Log.i(TAG, "📊 Min buffer size: $minBufferSize bytes")

            // Create AudioRecord with playback capture
            audioRecord = AudioRecord.Builder()
                .setAudioFormat(audioFormat)
                .setBufferSizeInBytes(minBufferSize * 4)
                .setAudioPlaybackCaptureConfig(config)
                .build()

            val state = audioRecord?.state
            Log.i(TAG, "✅ Audio capture configured: $SAMPLE_RATE Hz, $CHANNEL_COUNT channels")
            Log.i(TAG, "📊 AudioRecord state: $state (${if (state == AudioRecord.STATE_INITIALIZED) "INITIALIZED" else "NOT INITIALIZED"})")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to setup audio capture", e)
            throw e
        }
    }

    private fun setupEncoder() {
        // Create AAC format
        val format = MediaFormat.createAudioFormat(MIME_TYPE, SAMPLE_RATE, CHANNEL_COUNT).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, android.media.MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
        }

        // Create and configure codec
        mediaCodec = MediaCodec.createEncoderByType(MIME_TYPE).apply {
            configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            start()
        }

        Log.i(TAG, "Audio encoder configured: AAC-LC @ $BIT_RATE bps")
    }

    private fun encodeLoop() {
        audioRecord?.startRecording()
        Log.i(TAG, "Audio recording started")

        running = true
        val bufferInfo = MediaCodec.BufferInfo()

        while (running) {
            try {
                // Feed input to encoder
                feedInputToEncoder()

                // Get output from encoder
                val encoderStatus = mediaCodec?.dequeueOutputBuffer(bufferInfo, TIMEOUT_USEC) ?: continue

                when {
                    encoderStatus == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        // No output available yet
                    }
                    encoderStatus == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val newFormat = mediaCodec?.outputFormat
                        Log.i(TAG, "📢 Output format changed: $newFormat")

                        // Check if csd-0 exists
                        val csdBuffer = newFormat?.getByteBuffer("csd-0")
                        if (csdBuffer != null) {
                            val csd = ByteArray(csdBuffer.remaining())
                            csdBuffer.get(csd)
                            val csdHex = csd.joinToString(" ") { "%02X".format(it) }
                            Log.i(TAG, "✅ Found CSD-0: ${csd.size} bytes - $csdHex")
                            // Send as AUDIO_CONFIG packet (type 3)
                            networkServer.sendPacket(NetworkServer.PACKET_TYPE_AUDIO_CONFIG, csd)
                            Log.i(TAG, "✅ Sent AUDIO_CONFIG packet")
                        } else {
                            Log.w(TAG, "❌ CSD-0 not found in format!")
                            // Try to construct AudioSpecificConfig manually
                            // AAC-LC (2), 48kHz (3), Stereo (2)
                            val manualCSD = byteArrayOf(0x11.toByte(), 0x90.toByte())
                            Log.i(TAG, "🔧 Using manual AudioSpecificConfig: ${manualCSD.joinToString(" ") { "%02X".format(it) }}")
                            networkServer.sendPacket(NetworkServer.PACKET_TYPE_AUDIO_CONFIG, manualCSD)
                            Log.i(TAG, "✅ Sent manual AUDIO_CONFIG packet")
                        }
                    }
                    encoderStatus >= 0 -> {
                        val encodedData = mediaCodec?.getOutputBuffer(encoderStatus)

                        if (encodedData != null && bufferInfo.size > 0) {
                            // Send encoded audio packet
                            val audioData = ByteArray(bufferInfo.size)
                            encodedData.position(bufferInfo.offset)
                            encodedData.limit(bufferInfo.offset + bufferInfo.size)
                            encodedData.get(audioData)

                            networkServer.sendPacket(NetworkServer.PACKET_TYPE_AUDIO, audioData)
                            Log.v(TAG, "📤 Sent audio packet: ${bufferInfo.size} bytes, timestamp: ${bufferInfo.presentationTimeUs}")
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

    private fun feedInputToEncoder() {
        val inputBufferIndex = mediaCodec?.dequeueInputBuffer(TIMEOUT_USEC) ?: return

        if (inputBufferIndex >= 0) {
            val inputBuffer = mediaCodec?.getInputBuffer(inputBufferIndex) ?: return

            // Read audio data from AudioRecord
            val readBytes = audioRecord?.read(inputBuffer, inputBuffer.capacity()) ?: 0

            if (readBytes > 0) {
                Log.v(TAG, "📥 Read $readBytes bytes from AudioRecord")
                // Queue the input buffer
                mediaCodec?.queueInputBuffer(
                    inputBufferIndex,
                    0,
                    readBytes,
                    System.nanoTime() / 1000,
                    0
                )
            } else if (readBytes < 0) {
                Log.e(TAG, "❌ AudioRecord read error: $readBytes")
            }
        }
    }

    fun stopEncoding() {
        running = false
    }

    private fun release() {
        Log.i(TAG, "Releasing audio encoder")

        try {
            audioRecord?.stop()
            audioRecord?.release()
            audioRecord = null
        } catch (e: Exception) {
            Log.e(TAG, "Error releasing audio record", e)
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
