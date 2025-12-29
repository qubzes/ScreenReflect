//
//  H264Decoder.swift
//  ScreenReflect
//
//  H.264 decoder using VideoToolbox with synchronous decoding for frame order.
//

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import os.lock

/// H.264 video decoder
class H264Decoder: ObservableObject {

    // MARK: - Published Properties

    @Published var latestFrame: CVImageBuffer?
    @Published var latestFramePTS: CMTime = .zero
    @Published var isConfigured: Bool = false

    // MARK: - Private Properties

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var spsData: Data?
    private var ppsData: Data?
    private var frameCount: Int = 0
    
    private var sessionLock = os_unfair_lock()
    
    // Pre-allocated buffer for AVCC conversion
    private var avccBuffer = Data(capacity: 512 * 1024)

    // MARK: - Configuration

    func processConfig(data: Data) {
        print("[H264Decoder] Processing CONFIG packet (\(data.count) bytes)")

        let nalUnits = parseAnnexBNALUnits(from: data)

        var foundSPS: Data?
        var foundPPS: Data?
        
        for nalUnit in nalUnits {
            guard nalUnit.count > 0 else { continue }
            let nalType = nalUnit[0] & 0x1F

            switch nalType {
            case 7:
                foundSPS = nalUnit
                print("[H264Decoder] Found SPS (\(nalUnit.count) bytes)")
            case 8:
                foundPPS = nalUnit
                print("[H264Decoder] Found PPS (\(nalUnit.count) bytes)")
            default:
                break
            }
        }

        guard let sps = foundSPS, let pps = foundPPS else { return }
        
        os_unfair_lock_lock(&sessionLock)
        
        let spsChanged = spsData != sps
        let ppsChanged = ppsData != pps
        
        if spsChanged || ppsChanged {
            spsData = sps
            ppsData = pps
            
            if let session = decompressionSession {
                VTDecompressionSessionInvalidate(session)
                decompressionSession = nil
                formatDescription = nil
            }
            
            createDecompressionSessionLocked()
        }
        
        os_unfair_lock_unlock(&sessionLock)
    }

    private func createDecompressionSessionLocked() {
        guard let spsData = spsData, let ppsData = ppsData else { return }

        var formatDesc: CMVideoFormatDescription?

        let status = spsData.withUnsafeBytes { spsBytes -> OSStatus in
            let spsPointer = spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return ppsData.withUnsafeBytes { ppsBytes -> OSStatus in
                let ppsPointer = ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                var pointers: [UnsafePointer<UInt8>] = [spsPointer, ppsPointer]
                var sizes: [Int] = [spsData.count, ppsData.count]
                return pointers.withUnsafeMutableBufferPointer { pointersBuffer in
                    sizes.withUnsafeMutableBufferPointer { sizesBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointersBuffer.baseAddress!,
                            parameterSetSizes: sizesBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &formatDesc
                        )
                    }
                }
            }
        }

        guard status == noErr, let formatDescription = formatDesc else {
            print("[H264Decoder] Failed to create format description: \(status)")
            return
        }

        self.formatDescription = formatDescription

        var session: VTDecompressionSession?
        
        // Pixel buffer attributes for Metal rendering
        let sessionAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        // Request hardware acceleration
        let decoderSpec: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true
        ]

        // SYNCHRONOUS callback - called on decode thread in frame order
        var callbackRecord = VTDecompressionOutputCallbackRecord()
        callbackRecord.decompressionOutputCallback = { (
            decompressionOutputRefCon, _, status, infoFlags, imageBuffer, pts, _
        ) in
            guard let decoderPtr = decompressionOutputRefCon,
                  status == noErr,
                  let imageBuffer = imageBuffer else { return }
            
            let decoder = Unmanaged<H264Decoder>.fromOpaque(decoderPtr).takeUnretainedValue()
            
            if infoFlags.contains(.frameDropped) {
                return
            }
            
            // Direct update on main thread
            DispatchQueue.main.async {
                decoder.latestFrame = imageBuffer
                decoder.latestFramePTS = pts
            }
        }
        callbackRecord.decompressionOutputRefCon = Unmanaged.passUnretained(self).toOpaque()

        let result = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpec as CFDictionary,
            imageBufferAttributes: sessionAttributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &session
        )

        guard result == noErr, let decompressionSession = session else {
            print("[H264Decoder] Failed to create session: \(result)")
            return
        }

        // Real-time mode
        VTSessionSetProperty(decompressionSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        self.decompressionSession = decompressionSession
        
        DispatchQueue.main.async { self.isConfigured = true }
        print("[H264Decoder] ✅ Session created (real-time, hardware accelerated)")
    }

    // MARK: - Decoding

    func decode(data: Data) {
        os_unfair_lock_lock(&sessionLock)
        let session = decompressionSession
        let format = formatDescription
        os_unfair_lock_unlock(&sessionLock)
        
        guard let decompressionSession = session, let formatDescription = format else {
            return
        }

        // Convert Annex B to AVCC
        convertAnnexBToAVCC(data)
        
        guard avccBuffer.count > 0 else { return }
        
        let avccData = avccBuffer

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avccData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avccData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let blockBuffer = blockBuffer else { return }

        status = avccData.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avccData.count
            )
        }
        guard status == noErr else { return }

        var sampleBuffer: CMSampleBuffer?
        
        // Use frame count for monotonic timestamps
        let pts = CMTime(value: Int64(frameCount), timescale: 60)
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sampleBuffer = sampleBuffer else { return }

        // SYNCHRONOUS decode to maintain frame order
        var flagsOut: VTDecodeInfoFlags = []
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: [._1xRealTimePlayback],  // Synchronous, real-time
            frameRefcon: nil,
            infoFlagsOut: &flagsOut
        )

        if decodeStatus != noErr && decodeStatus != kVTInvalidSessionErr {
            print("[H264Decoder] Decode error: \(decodeStatus)")
        }

        frameCount += 1
    }

    // MARK: - NAL Unit Parsing

    private func parseAnnexBNALUnits(from data: Data) -> [Data] {
        var nalUnits: [Data] = []
        var currentIndex = 0

        while currentIndex < data.count {
            guard let startCodeRange = findNextStartCode(in: data, from: currentIndex) else { break }
            let nalStart = startCodeRange.upperBound
            var nalEnd = data.count
            if let nextRange = findNextStartCode(in: data, from: nalStart) {
                nalEnd = nextRange.lowerBound
            }
            if nalStart < nalEnd {
                nalUnits.append(Data(data[nalStart..<nalEnd]))
            }
            currentIndex = nalStart
        }
        return nalUnits
    }

    private func findNextStartCode(in data: Data, from index: Int) -> Range<Int>? {
        var i = index
        while i < data.count - 2 {
            if data[i] == 0x00 && data[i + 1] == 0x00 {
                if data[i + 2] == 0x01 {
                    return i..<(i + 3)
                } else if i < data.count - 3 && data[i + 2] == 0x00 && data[i + 3] == 0x01 {
                    return i..<(i + 4)
                }
            }
            i += 1
        }
        return nil
    }

    private func convertAnnexBToAVCC(_ data: Data) {
        avccBuffer.removeAll(keepingCapacity: true)
        let nalUnits = parseAnnexBNALUnits(from: data)
        for nalUnit in nalUnits {
            // Skip SPS/PPS in stream - we handle them separately
            let nalType = nalUnit[0] & 0x1F
            if nalType == 7 || nalType == 8 {
                continue
            }
            var length = UInt32(nalUnit.count).bigEndian
            avccBuffer.append(Data(bytes: &length, count: 4))
            avccBuffer.append(nalUnit)
        }
    }

    // MARK: - Lifecycle
    
    func prepareForDimensionChange(newDimensions: CGSize) {
        print("[H264Decoder] Dimension change to \(Int(newDimensions.width))x\(Int(newDimensions.height))")
    }

    func reset() {
        os_unfair_lock_lock(&sessionLock)
        
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
        formatDescription = nil
        spsData = nil
        ppsData = nil
        frameCount = 0
        
        os_unfair_lock_unlock(&sessionLock)
        
        DispatchQueue.main.async {
            self.latestFrame = nil
            self.latestFramePTS = .zero
            self.isConfigured = false
        }
    }

    deinit {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
    }
}
