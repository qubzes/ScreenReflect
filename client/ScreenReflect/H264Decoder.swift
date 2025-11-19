//
//  H264Decoder.swift
//  ScreenReflect
//
//  Decodes H.264 video stream using Apple's VideoToolbox framework.
//

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// H.264 video decoder using VideoToolbox
@MainActor
class H264Decoder: ObservableObject {

    // MARK: - Published Propertiess

    /// Latest decoded video frame (CVImageBuffer)
    @Published var latestFrame: CVImageBuffer?
    
    /// Latest frame presentation timestamp
    @Published var latestFramePTS: CMTime = .zero

    /// Decoder status
    @Published var isConfigured: Bool = false

    // MARK: - Private Properties

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?

    // SPS and PPS parameter sets
    private var spsData: Data?
    private var ppsData: Data?

    // Frame counter for debugging
    private var frameCount: Int = 0

    // MARK: - Configuration

    /// Process the CONFIG packet containing SPS/PPS
    func processConfig(data: Data) {
        print("[H264Decoder] Processing CONFIG packet (\(data.count) bytes)")

        // Parse NAL units from the config data
        // The data contains H.264 parameter sets in Annex B format
        let nalUnits = parseAnnexBNALUnits(from: data)

        for nalUnit in nalUnits {
            guard nalUnit.count > 0 else { continue }

            let nalType = nalUnit[0] & 0x1F

            switch nalType {
            case 7: // SPS
                spsData = nalUnit
                print("[H264Decoder] Found SPS (\(nalUnit.count) bytes)")

            case 8: // PPS
                ppsData = nalUnit
                print("[H264Decoder] Found PPS (\(nalUnit.count) bytes)")

            default:
                break // Silently ignore other NAL types
            }
        }

        // Create decompression session if we have both SPS and PPS
        if spsData != nil && ppsData != nil {
            createDecompressionSession()
        }
    }

    /// Create the VideoToolbox decompression session
    private func createDecompressionSession() {
        guard let spsData = spsData, let ppsData = ppsData else {
            print("[H264Decoder] Cannot create session: missing SPS or PPS")
            return
        }

        // Clean up existing session
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }

        // Create format description from SPS/PPS
        var formatDesc: CMVideoFormatDescription?

        let status = spsData.withUnsafeBytes { spsBytes -> OSStatus in
            let spsPointer = spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)

            return ppsData.withUnsafeBytes { ppsBytes -> OSStatus in
                let ppsPointer = ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)

                // Create array of pointers
                var pointers: [UnsafePointer<UInt8>] = [spsPointer, ppsPointer]
                var sizes: [Int] = [spsData.count, ppsData.count]

                return pointers.withUnsafeMutableBufferPointer { pointersBuffer in
                    sizes.withUnsafeMutableBufferPointer { sizesBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointersBuffer.baseAddress!,
                            parameterSetSizes: sizesBuffer.baseAddress!,
                            nalUnitHeaderLength: 4, // AVCC format uses 4-byte length
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

        // Callback context
        var callbackRecord = VTDecompressionOutputCallbackRecord()
        callbackRecord.decompressionOutputCallback = { (
            decompressionOutputRefCon: UnsafeMutableRawPointer?,
            sourceFrameRefCon: UnsafeMutableRawPointer?,
            status: OSStatus,
            infoFlags: VTDecodeInfoFlags,
            imageBuffer: CVImageBuffer?,
            presentationTimeStamp: CMTime,
            presentationDuration: CMTime
        ) in
            // Extract decoder instance from context
            guard let decoderPtr = decompressionOutputRefCon else { return }
            let decoder = Unmanaged<H264Decoder>.fromOpaque(decoderPtr).takeUnretainedValue()

            guard status == noErr else {
                print("[H264Decoder] Decode error: \(status)")
                return
            }

            guard let imageBuffer = imageBuffer else {
                print("[H264Decoder] No image buffer in callback")
                return
            }

            // Update the published property on main actor
            Task { @MainActor in
                decoder.latestFrame = imageBuffer
                decoder.latestFramePTS = presentationTimeStamp
            }
        }

        callbackRecord.decompressionOutputRefCon = Unmanaged.passUnretained(self).toOpaque()

        // Session attributes - optimize for performance
        let sessionAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary // Enable zero-copy rendering
        ]

        // Decoder specifications - use hardware acceleration
        let decoderSpec: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true
        ]

        // Create decompression session
        var session: VTDecompressionSession?
        let result = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpec as CFDictionary,
            imageBufferAttributes: sessionAttributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &session
        )

        guard result == noErr, let decompressionSession = session else {
            print("[H264Decoder] Failed to create decompression session: \(result)")
            return
        }

        self.decompressionSession = decompressionSession
        self.isConfigured = true

        print("[H264Decoder] ✅ Decompression session created successfully")
        print("[H264Decoder] SPS: \(spsData.count) bytes, PPS: \(ppsData.count) bytes")
    }

    // MARK: - Decoding

    /// Decode a video frame
    func decode(data: Data) {
        guard let decompressionSession = decompressionSession,
              let formatDescription = formatDescription else {
            print("[H264Decoder] Cannot decode: session not configured")
            return
        }

        // Convert Annex B format to AVCC format
        let avccData = convertAnnexBToAVCC(data)

        // Create block buffer
        var blockBuffer: CMBlockBuffer?
        let bufferStatus = avccData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            CMBlockBufferCreateWithMemoryBlock(
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
        }

        guard bufferStatus == noErr, let blockBuffer = blockBuffer else {
            print("[H264Decoder] Failed to create block buffer: \(bufferStatus)")
            return
        }

        // Copy data into block buffer
        let replaceStatus = avccData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avccData.count
            )
        }

        guard replaceStatus == noErr else {
            print("[H264Decoder] Failed to copy data to block buffer: \(replaceStatus)")
            return
        }

        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(frameCount), timescale: 60),  // 60fps
            decodeTimeStamp: .invalid
        )

        let sampleStatus = CMSampleBufferCreateReady(
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

        guard sampleStatus == noErr, let sampleBuffer = sampleBuffer else {
            print("[H264Decoder] Failed to create sample buffer: \(sampleStatus)")
            return
        }

        // Decode the frame with real-time flags for low latency
        var flagsOut: VTDecodeInfoFlags = []
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression, ._EnableTemporalProcessing],
            frameRefcon: nil,
            infoFlagsOut: &flagsOut
        )

        if decodeStatus != noErr {
            print("[H264Decoder] Decode frame failed: \(decodeStatus)")
        }

        frameCount += 1
    }

    // MARK: - NAL Unit Parsing

    /// Parse NAL units from Annex B format (0x00 0x00 0x01 start codes)
    private func parseAnnexBNALUnits(from data: Data) -> [Data] {
        var nalUnits: [Data] = []
        var currentIndex = 0

        while currentIndex < data.count {
            // Find next start code
            guard let startCodeRange = findNextStartCode(in: data, from: currentIndex) else {
                break
            }

            let nalStart = startCodeRange.upperBound

            // Find the next start code (or end of data)
            var nalEnd = data.count
            if let nextStartCodeRange = findNextStartCode(in: data, from: nalStart) {
                nalEnd = nextStartCodeRange.lowerBound
            }

            // Extract NAL unit
            if nalStart < nalEnd {
                let nalUnit = data[nalStart..<nalEnd]
                nalUnits.append(Data(nalUnit))
            }

            currentIndex = nalStart
        }

        return nalUnits
    }

    /// Find the next Annex B start code (0x00 0x00 0x01 or 0x00 0x00 0x00 0x01)
    private func findNextStartCode(in data: Data, from index: Int) -> Range<Int>? {
        var i = index

        while i < data.count - 2 {
            if data[i] == 0x00 && data[i + 1] == 0x00 {
                if data[i + 2] == 0x01 {
                    // Found 3-byte start code
                    return i..<(i + 3)
                } else if i < data.count - 3 && data[i + 2] == 0x00 && data[i + 3] == 0x01 {
                    // Found 4-byte start code
                    return i..<(i + 4)
                }
            }
            i += 1
        }

        return nil
    }

    /// Convert Annex B format to AVCC format (replace start codes with 4-byte lengths)
    private func convertAnnexBToAVCC(_ data: Data) -> Data {
        var avccData = Data()
        let nalUnits = parseAnnexBNALUnits(from: data)

        for nalUnit in nalUnits {
            // Write 4-byte big-endian length
            var length = UInt32(nalUnit.count).bigEndian
            avccData.append(Data(bytes: &length, count: 4))

            // Write NAL unit data
            avccData.append(nalUnit)
        }

        return avccData
    }

    // MARK: - Reset

    /// Reset the decoder state for reconnection
    func reset() {
        print("[H264Decoder] Resetting decoder state")

        // Invalidate existing session
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }

        // Clear all state
        decompressionSession = nil
        formatDescription = nil
        spsData = nil
        ppsData = nil
        latestFrame = nil
        latestFramePTS = .zero
        isConfigured = false
        frameCount = 0
    }

    // MARK: - Cleanup

    deinit {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
    }
}
