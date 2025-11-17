//
//  AACDecoder.swift
//  ScreenReflect
//
//  Decodes and plays AAC audio stream using AudioToolbox and AVFoundation.
//

import Foundation
import AVFoundation
import AudioToolbox
import os.log

/// AAC audio decoder and player
@MainActor
class AACDecoder: ObservableObject {

    private let logger = Logger(subsystem: "com.screenreflect.ScreenReflect", category: "AACDecoder")

    // MARK: - Published Properties

    @Published var isPlaying: Bool = false

    // MARK: - Private Properties

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioConverter: AudioConverterRef?

    // Audio formats
    private var inputFormat: AudioStreamBasicDescription  // AAC format
    private var outputFormat: AudioStreamBasicDescription // PCM format

    // Buffer for decoded PCM data
    private var pcmBuffer: UnsafeMutablePointer<UInt8>?
    private let pcmBufferSize: UInt32 = 32768 // 32KB buffer

    // MARK: - Initialization

    init() {
        // Setup AAC input format (48kHz, stereo, as configured by Android)
        inputFormat = AudioStreamBasicDescription(
            mSampleRate: 48000.0,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,  // FIXED: Must be 0 for AAC (object type is in magic cookie)
            mBytesPerPacket: 0,  // Variable for compressed
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        // Setup PCM output format (Linear PCM, non-interleaved float32)
        outputFormat = AudioStreamBasicDescription(
            mSampleRate: 48000.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,  // 4 bytes per channel (float32)
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,   // 4 bytes per channel
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        // Allocate PCM buffer
        pcmBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(pcmBufferSize))

        setupAudioConverter()
        setupAudioEngine()
    }

    // MARK: - Setup

    private func setupAudioConverter() {
        var inFormat = inputFormat
        var outFormat = outputFormat

        let status = AudioConverterNew(&inFormat, &outFormat, &audioConverter)

        if status == noErr {
            logger.info("✅ Audio converter created successfully")
            // Magic cookie will be set when we receive the AudioSpecificConfig from Android
        } else {
            logger.error("❌ Failed to create audio converter: \(status)")
        }
    }

    /// Set AudioSpecificConfig (CSD-0) from Android as magic cookie
    func setAudioSpecificConfig(data: Data) {
        guard let converter = audioConverter else {
            logger.error("❌ Cannot set magic cookie - no converter")
            return
        }

        logger.info("📡 Setting AudioSpecificConfig from Android: \(data.count) bytes")

        // Print the config bytes for debugging
        let bytes = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        logger.info("📡 AudioSpecificConfig bytes: \(bytes)")

        var configData = data
        let status = configData.withUnsafeMutableBytes { (rawBufferPointer: UnsafeMutableRawBufferPointer) -> OSStatus in
            let bufferPointer = rawBufferPointer.bindMemory(to: UInt8.self)
            guard let baseAddress = bufferPointer.baseAddress else { return -1 }

            return AudioConverterSetProperty(
                converter,
                kAudioConverterDecompressionMagicCookie,
                UInt32(data.count),
                baseAddress
            )
        }

        if status == noErr {
            logger.info("✅ AudioSpecificConfig set successfully!")
        } else {
            logger.error("❌ Failed to set AudioSpecificConfig: \(status)")
        }
    }

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        guard let engine = audioEngine, let player = playerNode else {
            print("[AACDecoder] Failed to create audio engine or player node")
            return
        }

        // Attach the player node
        engine.attach(player)

        // Create format for the player (PCM, 48kHz, stereo, float)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000.0,
            channels: 2,
            interleaved: false
        ) else {
            print("[AACDecoder] Failed to create AVAudioFormat")
            return
        }

        // Connect player to main mixer
        engine.connect(player, to: engine.mainMixerNode, format: format)

        print("[AACDecoder] Audio engine configured: 48000Hz, 2 channels")

        // Start the engine
        do {
            try engine.start()
            print("[AACDecoder] Audio engine started")
        } catch {
            print("[AACDecoder] Failed to start audio engine: \(error)")
        }
    }

    // MARK: - Playback Control

    func start() {
        guard let player = playerNode, !isPlaying else {
            print("[AACDecoder] Cannot start - player=\(playerNode != nil), isPlaying=\(isPlaying)")
            return
        }

        player.play()
        isPlaying = true
        print("[AACDecoder] ✅ Audio playback started - player.isPlaying=\(player.isPlaying)")
    }

    func stop() {
        guard let player = playerNode, isPlaying else { return }

        player.stop()
        isPlaying = false
        print("[AACDecoder] Audio playback stopped")
    }

    // MARK: - ADTS Header

    /// Add ADTS header to raw AAC frame for decoding
    /// ADTS = Audio Data Transport Stream
    private func addADTSHeader(to aacFrame: Data) -> Data {
        let aacFrameLength = aacFrame.count
        let adtsLength = 7  // ADTS header is 7 bytes
        let fullLength = adtsLength + aacFrameLength

        var adtsHeader = Data(count: adtsLength)

        // ADTS header structure:
        // Byte 0-1: Sync word (0xFFF), MPEG version, Layer, Protection absent
        // Byte 2: Profile, Sample rate, Channel config
        // Byte 3-6: Frame length, Buffer fullness, Number of frames

        adtsHeader[0] = 0xFF  // Sync word (12 bits) - part 1
        adtsHeader[1] = 0xF1  // Sync word + MPEG-4 + Layer=0 + No CRC

        // Profile (AAC-LC = 1), Sample Rate Index (48kHz = 3), Channel Config (Stereo = 2)
        // Binary: 01 0011 0 0 = 0x4C (Profile=1, SampleRate=3 for 48kHz, Private=0, ChannelMSB=0)
        adtsHeader[2] = 0x4C  // FIXED: Was 0x50 (44.1kHz), now 0x4C (48kHz)
        adtsHeader[3] = 0x80  // ChannelConfig=2 (bit 7-6 LSB), Frame length (bits 5-0 MSB)

        // Frame length (13 bits total = adtsLength + aacFrameLength)
        adtsHeader[3] = UInt8(0x80 | ((fullLength >> 11) & 0x03))
        adtsHeader[4] = UInt8((fullLength >> 3) & 0xFF)
        adtsHeader[5] = UInt8(((fullLength & 0x07) << 5) | 0x1F)

        // Buffer fullness (0x7FF = VBR)
        adtsHeader[6] = 0xFC

        // Combine header + frame
        var result = adtsHeader
        result.append(aacFrame)

        return result
    }

    // MARK: - Decoding

    /// Decode and play AAC audio data
    func decode(data: Data) {
        logger.debug("📥 Received AAC data: \(data.count) bytes")

        // Inspect first few bytes to see the format
        if data.count >= 4 {
            let bytes = data.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " ")
            logger.debug("📥 First 4 bytes: \(bytes)")
        }

        // Auto-start playback on first packet
        if !isPlaying {
            logger.info("▶️ Starting audio playback...")
            start()
        }

        guard let player = playerNode,
              let converter = audioConverter else {
            logger.error("❌ Missing player or converter!")
            return
        }

        // Create format for playback
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000.0,
            channels: 2,
            interleaved: false
        ) else { return }

        // Android sends raw AAC frames - use them directly with magic cookie
        let inputData = data
        print("[AACDecoder] Using raw AAC data: \(inputData.count) bytes")

        // Create a buffer to hold the input data (will be released by the callback)
        let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputData.count)
        inputData.copyBytes(to: inputBuffer, count: inputData.count)

        // AudioConverter input callback
        let inputCallback: AudioConverterComplexInputDataProc = { (
            converter,
            ioNumberDataPackets,
            ioData,
            outDataPacketDescription,
            inUserData
        ) -> OSStatus in
            guard let userData = inUserData else {
                print("[AACDecoder] ❌ Input callback: no userData")
                return -1
            }

            // Extract the context
            let context = Unmanaged<AudioConverterContext>.fromOpaque(userData).takeUnretainedValue()

            print("[AACDecoder] Input callback called: offset=\(context.offset), dataSize=\(context.data.count), requestedPackets=\(ioNumberDataPackets.pointee)")

            // Check if we've already provided the data
            if context.offset >= context.data.count {
                print("[AACDecoder] Input callback: No more data (EOF)")
                ioNumberDataPackets.pointee = 0
                return noErr
            }

            // Provide the entire AAC frame as one packet
            print("[AACDecoder] Input callback: providing \(context.data.count) bytes as 1 packet")

            ioData.pointee.mNumberBuffers = 1
            ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(context.buffer)
            ioData.pointee.mBuffers.mDataByteSize = UInt32(context.data.count)
            ioData.pointee.mBuffers.mNumberChannels = 2

            // CRITICAL FIX: Provide packet description for raw AAC
            if let packetDescPtr = outDataPacketDescription, let packetDesc = packetDescPtr.pointee {
                packetDesc.pointee = AudioStreamPacketDescription(
                    mStartOffset: 0,
                    mVariableFramesInPacket: 0,
                    mDataByteSize: UInt32(context.data.count)
                )
            }

            context.offset = context.data.count // Mark as consumed
            ioNumberDataPackets.pointee = 1

            return noErr
        }

        // Create context for the callback
        let context = AudioConverterContext(data: inputData, offset: 0, buffer: inputBuffer)
        let contextPtr = Unmanaged.passRetained(context).toOpaque()
        defer {
            Unmanaged<AudioConverterContext>.fromOpaque(contextPtr).release()
            inputBuffer.deallocate() // Clean up the buffer
        }

        // Prepare output buffer list with 2 buffers for non-interleaved stereo
        // Allocate temporary buffers for left and right channels
        let channelBufferSize = pcmBufferSize / 2
        let leftBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(channelBufferSize))
        let rightBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(channelBufferSize))
        defer {
            leftBuffer.deallocate()
            rightBuffer.deallocate()
        }

        // Create buffer list with 2 buffers (one per channel)
        var outputBufferList = AudioBufferList()
        outputBufferList.mNumberBuffers = 2

        let buffers = UnsafeMutableBufferPointer<AudioBuffer>.allocate(capacity: 2)
        defer { buffers.deallocate() }

        buffers[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: channelBufferSize,
            mData: UnsafeMutableRawPointer(leftBuffer)
        )
        buffers[1] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: channelBufferSize,
            mData: UnsafeMutableRawPointer(rightBuffer)
        )

        // Set the buffers in the AudioBufferList
        withUnsafeMutablePointer(to: &outputBufferList.mBuffers) { buffersPointer in
            buffersPointer.withMemoryRebound(to: AudioBuffer.self, capacity: 2) { audioBuffersPointer in
                audioBuffersPointer[0] = buffers[0]
                audioBuffersPointer[1] = buffers[1]
            }
        }

        // Convert AAC to PCM
        var ioOutputDataPacketSize: UInt32 = 1024
        let status = AudioConverterFillComplexBuffer(
            converter,
            inputCallback,
            contextPtr,
            &ioOutputDataPacketSize,
            &outputBufferList,
            nil
        )

        guard status == noErr else {
            logger.error("❌ AudioConverter failed with status: \(status)")
            logger.error("❌ Decoder error details - input size: \(inputData.count) bytes, requested frames: \(ioOutputDataPacketSize)")
            return
        }

        logger.info("✅ AudioConverter decoded \(ioOutputDataPacketSize) frames successfully")

        // Create AVAudioPCMBuffer from decoded data
        let frameCapacity = AVAudioFrameCount(1024)
        guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return
        }

        audioBuffer.frameLength = ioOutputDataPacketSize

        // Copy decoded PCM data from separate channel buffers to AVAudioPCMBuffer
        if let channelData = audioBuffer.floatChannelData {
            // Calculate bytes per channel (float32 = 4 bytes per sample)
            let frameCount = Int(ioOutputDataPacketSize)
            let bytesPerChannel = frameCount * 4

            // Copy left channel from leftBuffer
            memcpy(channelData[0], leftBuffer, bytesPerChannel)

            // Copy right channel from rightBuffer
            memcpy(channelData[1], rightBuffer, bytesPerChannel)
        }

        // Schedule the buffer for playback
        player.scheduleBuffer(audioBuffer, completionHandler: nil)
        logger.info("🔊 Scheduled audio buffer (\(ioOutputDataPacketSize) frames) for playback")

        // Verify player is actually playing
        if !player.isPlaying {
            logger.warning("⚠️ Player is not playing! Attempting to start...")
            player.play()
        }
    }

    // MARK: - Helper Classes

    /// Context for AudioConverter input callback
    private class AudioConverterContext {
        let data: Data
        var offset: Int
        let buffer: UnsafeMutablePointer<UInt8>

        init(data: Data, offset: Int, buffer: UnsafeMutablePointer<UInt8>) {
            self.data = data
            self.offset = offset
            self.buffer = buffer
        }
    }

    // MARK: - Cleanup

    nonisolated deinit {
        // Clean up audio resources
        if let engine = audioEngine {
            engine.stop()
        }

        if let player = playerNode {
            player.stop()
        }

        if let converter = audioConverter {
            AudioConverterDispose(converter)
        }

        pcmBuffer?.deallocate()
    }
}
