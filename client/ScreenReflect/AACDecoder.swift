//
//  AACDecoder.swift
//  ScreenReflect
//
//  AAC/ADTS audio decoder with large buffers for smooth, crack-free audio.
//

import Foundation
import AVFoundation
import AudioToolbox
import os.log

class AACDecoder: ObservableObject {

    private let logger = Logger(subsystem: "com.screenreflect.ScreenReflect", category: "AACDecoder")

    @Published var isPlaying: Bool = false

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

    private let lock = NSLock()
    
    // Smaller buffer to sync audio ahead with video
    private var pendingBuffers: Int = 0
    private let maxPendingBuffers: Int = 8  // ~170ms buffer - sync with video
    
    // Pre-allocated buffers
    private var inputBufferCapacity: Int = 8192
    private var channelBufferCapacity: Int = 32768
    private var reusableInputBuffer: UnsafeMutablePointer<UInt8>?
    private var reusableLeftBuffer: UnsafeMutablePointer<UInt8>?
    private var reusableRightBuffer: UnsafeMutablePointer<UInt8>?
    
    private var cachedAudioFormat: AVAudioFormat?

    init() {
        allocateBuffers()
        setupAudioEngine()
    }
    
    private func allocateBuffers() {
        reusableInputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputBufferCapacity)
        reusableLeftBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: channelBufferCapacity)
        reusableRightBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: channelBufferCapacity)
        
        cachedAudioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000.0,
            channels: 2,
            interleaved: false
        )
    }

    func setAudioSpecificConfig(data: Data) {
        lock.lock()
        defer { lock.unlock() }
        
        logger.info("📡 Received AudioSpecificConfig (ADTS mode)")
        setupAudioConverter()
    }
    
    private func setupAudioConverter() {
        if let converter = audioConverter {
            AudioConverterDispose(converter)
            audioConverter = nil
        }
        
        var inFormat = AudioStreamBasicDescription(
            mSampleRate: 48000.0,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
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
            logger.info("✅ Audio converter created")
        } else {
            logger.error("❌ Failed to create audio converter: \(status)")
        }
    }

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        guard let engine = audioEngine, let player = playerNode else { return }

        engine.attach(player)

        guard let format = cachedAudioFormat else { return }

        engine.connect(player, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
            print("[AACDecoder] Audio engine started")
        } catch {
            print("[AACDecoder] Failed to start audio engine: \(error)")
        }
        
        pendingBuffers = 0
    }

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

    private func stripAdtsHeader(_ data: Data) -> Data? {
        guard data.count >= 7 else { return nil }
        
        guard data[0] == 0xFF && (data[1] & 0xF0) == 0xF0 else {
            return data
        }
        
        let hasCRC = (data[1] & 0x01) == 0
        let headerSize = hasCRC ? 9 : 7
        
        guard data.count > headerSize else { return nil }
        
        return data.subdata(in: headerSize..<data.count)
    }

    func decode(data: Data) {
        lock.lock()
        
        // Only drop if REALLY full (prevents cracks)
        if pendingBuffers >= maxPendingBuffers {
            lock.unlock()
            return
        }
        
        if audioConverter == nil {
            setupAudioConverter()
        }
        
        lock.unlock()
        
        if let player = playerNode, !player.isPlaying {
            start()
        }

        guard let player = playerNode,
              let converter = audioConverter,
              let format = cachedAudioFormat,
              let inputBuffer = reusableInputBuffer,
              let leftBuffer = reusableLeftBuffer,
              let rightBuffer = reusableRightBuffer else {
            return
        }

        guard let aacData = stripAdtsHeader(data) else { return }
        
        if aacData.count > inputBufferCapacity {
            reusableInputBuffer?.deallocate()
            inputBufferCapacity = aacData.count * 2
            reusableInputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputBufferCapacity)
            guard let newBuffer = reusableInputBuffer else { return }
            aacData.copyBytes(to: newBuffer, count: aacData.count)
        } else {
            aacData.copyBytes(to: inputBuffer, count: aacData.count)
        }
        
        let currentInputBuffer = reusableInputBuffer!

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

        let context = AudioConverterContext(data: aacData, offset: 0, buffer: currentInputBuffer)
        let contextPtr = Unmanaged.passRetained(context).toOpaque()
        defer {
            Unmanaged<AudioConverterContext>.fromOpaque(contextPtr).release()
        }

        let channelBufferSize = UInt32(channelBufferCapacity)

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

        guard status == noErr, ioOutputDataPacketSize > 0 else {
            return
        }

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
        reusableInputBuffer?.deallocate()
        reusableLeftBuffer?.deallocate()
        reusableRightBuffer?.deallocate()
    }
}
