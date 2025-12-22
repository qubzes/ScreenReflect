//
//  AACDecoder.swift
//  ScreenReflect
//
//  Decodes and plays AAC/ADTS audio stream.
//  ADTS frames are self-describing - no external config needed.
//

import Foundation
import AVFoundation
import AudioToolbox
import os.log

/// AAC/ADTS audio decoder - real-time mode
class AACDecoder: ObservableObject {

    private let logger = Logger(subsystem: "com.screenreflect.ScreenReflect", category: "AACDecoder")

    @Published var isPlaying: Bool = false

    // MARK: - Private Properties

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioConverter: AudioConverterRef?
    private var converterConfigured = false

    private let outputFormat = AudioStreamBasicDescription(
        mSampleRate: 48000.0,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 32,
        mReserved: 0
    )

    private var pcmBuffer: UnsafeMutablePointer<UInt8>?
    private let pcmBufferSize: UInt32 = 32768
    
    private let lock = NSLock()
    
    // Buffer limiting
    private var pendingBuffers: Int = 0
    private let maxPendingBuffers: Int = 5

    // MARK: - Initialization

    init() {
        pcmBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(pcmBufferSize))
        setupAudioEngine()
    }

    // MARK: - Setup

    func setAudioSpecificConfig(data: Data) {
        lock.lock()
        defer { lock.unlock() }
        
        logger.info("📡 Received AudioSpecificConfig (ADTS mode - will auto-configure)")
        // With ADTS, we don't need the config - the ADTS header has all info
        // But we use this signal to create the converter
        setupAudioConverter()
    }
    
    private func setupAudioConverter() {
        if let converter = audioConverter {
            AudioConverterDispose(converter)
            audioConverter = nil
        }
        
        // ADTS input format - AudioConverter can parse ADTS headers
        var inFormat = AudioStreamBasicDescription(
            mSampleRate: 48000.0,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,  // Variable
            mFramesPerPacket: 1024,  // Standard AAC frame size
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        
        var outFormat = outputFormat

        var newConverter: AudioConverterRef?
        let status = AudioConverterNew(&inFormat, &outFormat, &newConverter)
        
        if status == noErr, let converter = newConverter {
            self.audioConverter = converter
            self.converterConfigured = true
            logger.info("✅ Audio converter created for ADTS")
        } else {
            logger.error("❌ Failed to create audio converter: \(status)")
        }
    }

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        guard let engine = audioEngine, let player = playerNode else { return }

        engine.attach(player)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000.0,
            channels: 2,
            interleaved: false
        ) else { return }

        engine.connect(player, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
            print("[AACDecoder] Audio engine started")
        } catch {
            print("[AACDecoder] Failed to start audio engine: \(error)")
        }
        
        pendingBuffers = 0
    }

    // MARK: - Playback Control

    func start() {
        guard let player = playerNode, !player.isPlaying else { return }
        player.play()
        DispatchQueue.main.async { self.isPlaying = true }
    }

    func stop() {
        guard let player = playerNode, player.isPlaying else { return }
        player.stop()
        DispatchQueue.main.async { self.isPlaying = false }
    }

    // MARK: - ADTS Parsing
    
    /// Strip ADTS header (7 bytes) and return raw AAC data
    private func stripAdtsHeader(_ data: Data) -> Data? {
        // ADTS header is 7 bytes (or 9 with CRC)
        guard data.count >= 7 else { return nil }
        
        // Check sync word (0xFFF)
        guard data[0] == 0xFF && (data[1] & 0xF0) == 0xF0 else {
            // Not ADTS, return as-is (might be raw AAC)
            return data
        }
        
        // Check if CRC is present (protection absent bit)
        let hasCRC = (data[1] & 0x01) == 0
        let headerSize = hasCRC ? 9 : 7
        
        guard data.count > headerSize else { return nil }
        
        return data.subdata(in: headerSize..<data.count)
    }

    // MARK: - Decoding

    func decode(data: Data) {
        lock.lock()
        
        // Buffer limiting
        if pendingBuffers >= maxPendingBuffers {
            lock.unlock()
            return
        }
        
        lock.unlock()
        
        // Lazy setup converter on first decode
        if audioConverter == nil {
            lock.lock()
            setupAudioConverter()
            lock.unlock()
        }
        
        // Auto-start playback
        if let player = playerNode, !player.isPlaying {
            start()
        }

        guard let player = playerNode,
              let converter = audioConverter else { return }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000.0,
            channels: 2,
            interleaved: false
        ) else { return }

        // Strip ADTS header to get raw AAC data
        guard let aacData = stripAdtsHeader(data) else { return }
        
        let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: aacData.count)
        aacData.copyBytes(to: inputBuffer, count: aacData.count)

        let inputCallback: AudioConverterComplexInputDataProc = { (
            converter, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData
        ) -> OSStatus in
            guard let userData = inUserData else { return -1 }
            let context = Unmanaged<AudioConverterContext>.fromOpaque(userData).takeUnretainedValue()

            if context.offset >= context.data.count {
                ioNumberDataPackets.pointee = 0
                return noErr
            }

            ioData.pointee.mNumberBuffers = 1
            ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(context.buffer)
            ioData.pointee.mBuffers.mDataByteSize = UInt32(context.data.count)
            ioData.pointee.mBuffers.mNumberChannels = 2

            // Provide packet description for AAC
            if let packetDescPtr = outDataPacketDescription {
                let packetDesc = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
                packetDesc.pointee = AudioStreamPacketDescription(
                    mStartOffset: 0,
                    mVariableFramesInPacket: 0,
                    mDataByteSize: UInt32(context.data.count)
                )
                packetDescPtr.pointee = packetDesc
            }

            context.offset = context.data.count
            ioNumberDataPackets.pointee = 1
            return noErr
        }

        let context = AudioConverterContext(data: aacData, offset: 0, buffer: inputBuffer)
        let contextPtr = Unmanaged.passRetained(context).toOpaque()
        defer {
            Unmanaged<AudioConverterContext>.fromOpaque(contextPtr).release()
            inputBuffer.deallocate()
        }

        let channelBufferSize = pcmBufferSize / 2
        let leftBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(channelBufferSize))
        let rightBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(channelBufferSize))
        defer {
            leftBuffer.deallocate()
            rightBuffer.deallocate()
        }

        var outputBufferList = AudioBufferList()
        outputBufferList.mNumberBuffers = 2

        let buffers = UnsafeMutableBufferPointer<AudioBuffer>.allocate(capacity: 2)
        defer { buffers.deallocate() }

        buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: channelBufferSize, mData: UnsafeMutableRawPointer(leftBuffer))
        buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: channelBufferSize, mData: UnsafeMutableRawPointer(rightBuffer))

        withUnsafeMutablePointer(to: &outputBufferList.mBuffers) { buffersPointer in
            buffersPointer.withMemoryRebound(to: AudioBuffer.self, capacity: 2) { audioBuffersPointer in
                audioBuffersPointer[0] = buffers[0]
                audioBuffersPointer[1] = buffers[1]
            }
        }

        var ioOutputDataPacketSize: UInt32 = 1024
        let status = AudioConverterFillComplexBuffer(
            converter,
            inputCallback,
            contextPtr,
            &ioOutputDataPacketSize,
            &outputBufferList,
            nil
        )

        guard status == noErr, ioOutputDataPacketSize > 0 else { return }

        let frameCapacity = AVAudioFrameCount(1024)
        guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return }

        audioBuffer.frameLength = ioOutputDataPacketSize

        if let channelData = audioBuffer.floatChannelData {
            let frameCount = Int(ioOutputDataPacketSize)
            let bytesPerChannel = frameCount * 4
            memcpy(channelData[0], leftBuffer, bytesPerChannel)
            memcpy(channelData[1], rightBuffer, bytesPerChannel)
        }

        lock.lock()
        pendingBuffers += 1
        lock.unlock()
        
        player.scheduleBuffer(audioBuffer) { [weak self] in
            self?.lock.lock()
            self?.pendingBuffers -= 1
            self?.lock.unlock()
        }
        
        if !player.isPlaying {
            player.play()
        }
    }

    // MARK: - Helper Classes

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

    // MARK: - Reset

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        
        playerNode?.stop()
        audioEngine?.stop()
        pendingBuffers = 0
        converterConfigured = false
        
        if let converter = audioConverter {
            AudioConverterDispose(converter)
            audioConverter = nil
        }

        DispatchQueue.main.async { self.isPlaying = false }
        setupAudioEngine()
    }

    deinit {
        audioEngine?.stop()
        playerNode?.stop()
        if let converter = audioConverter {
            AudioConverterDispose(converter)
        }
        pcmBuffer?.deallocate()
    }
}
