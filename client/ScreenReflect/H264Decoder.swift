//
//  H264Decoder.swift
//  ScreenReflect
//
//  Decodes H.264 video stream using Apple's VideoToolbox framework.
//  Real-time optimized - trusts VideoToolbox's built-in frame management.
//

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// H.264 video decoder - real-time mode
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
    private let lock = NSLock()

    // MARK: - Configuration

    func processConfig(data: Data) {
        lock.lock()
        defer { lock.unlock() }
        
        print("[H264Decoder] Processing CONFIG packet (\(data.count) bytes)")

        let nalUnits = parseAnnexBNALUnits(from: data)

        for nalUnit in nalUnits {
            guard nalUnit.count > 0 else { continue }
            let nalType = nalUnit[0] & 0x1F

            switch nalType {
            case 7:
                spsData = nalUnit
                print("[H264Decoder] Found SPS (\(nalUnit.count) bytes)")
            case 8:
                ppsData = nalUnit
                print("[H264Decoder] Found PPS (\(nalUnit.count) bytes)")
            default:
                break
            }
        }

        if spsData != nil && ppsData != nil {
            if decompressionSession != nil {
                VTDecompressionSessionInvalidate(decompressionSession!)
                decompressionSession = nil
                formatDescription = nil
            }
            createDecompressionSession()
        }
    }

    private func createDecompressionSession() {
        guard let spsData = spsData, let ppsData = ppsData else { return }

        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }

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
        
        let sessionAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        let decoderSpec: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true
        ]

        var callbackRecord = VTDecompressionOutputCallbackRecord()
        callbackRecord.decompressionOutputCallback = { (
            decompressionOutputRefCon, _, status, _, imageBuffer, pts, _
        ) in
            guard let decoderPtr = decompressionOutputRefCon,
                  status == noErr,
                  let imageBuffer = imageBuffer else { return }
            
            let decoder = Unmanaged<H264Decoder>.fromOpaque(decoderPtr).takeUnretainedValue()
            
            // Update UI immediately
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

        // Enable real-time mode - VideoToolbox will handle frame dropping internally
        VTSessionSetProperty(decompressionSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        self.decompressionSession = decompressionSession
        
        DispatchQueue.main.async { self.isConfigured = true }
        print("[H264Decoder] ✅ Session created (real-time, hardware accelerated)")
    }

    // MARK: - Decoding

    func decode(data: Data) {
        lock.lock()
        defer { lock.unlock() }
        
        guard let decompressionSession = decompressionSession,
              let formatDescription = formatDescription else {
            return
        }

        let avccData = convertAnnexBToAVCC(data)

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
        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(frameCount), timescale: 60),
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

        var flagsOut: VTDecodeInfoFlags = []
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: [._1xRealTimePlayback],  // Let VideoToolbox manage frame timing
            frameRefcon: nil,
            infoFlagsOut: &flagsOut
        )

        if decodeStatus != noErr {
            print("[H264Decoder] Decode failed: \(decodeStatus)")
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

    private func convertAnnexBToAVCC(_ data: Data) -> Data {
        var avccData = Data()
        let nalUnits = parseAnnexBNALUnits(from: data)
        for nalUnit in nalUnits {
            var length = UInt32(nalUnit.count).bigEndian
            avccData.append(Data(bytes: &length, count: 4))
            avccData.append(nalUnit)
        }
        return avccData
    }

    // MARK: - Lifecycle
    
    func prepareForDimensionChange(newDimensions: CGSize) {
        lock.lock()
        defer { lock.unlock() }
        print("[H264Decoder] Dimension change to \(Int(newDimensions.width))x\(Int(newDimensions.height))")
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
        formatDescription = nil
        spsData = nil
        ppsData = nil
        frameCount = 0
        
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
