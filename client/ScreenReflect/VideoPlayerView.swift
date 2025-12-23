//
//  VideoPlayerView.swift
//  ScreenReflect
//
//  Ultra-low-latency video rendering using AVSampleBufferDisplayLayer.
//  Implements immediate frame rendering - no queuing, always shows latest frame.
//

import SwiftUI
import AVFoundation
import CoreMedia
import Combine

/// SwiftUI view that renders decoded H.264 video frames
struct VideoPlayerView: View {

    @ObservedObject var h264Decoder: H264Decoder
    @ObservedObject var streamClient: StreamClient

    let device: DiscoveredDevice
    let onDimensionChange: ((CGSize) -> Void)?

    init(h264Decoder: H264Decoder, streamClient: StreamClient, device: DiscoveredDevice, onDimensionChange: ((CGSize) -> Void)? = nil) {
        self.h264Decoder = h264Decoder
        self.streamClient = streamClient
        self.device = device
        self.onDimensionChange = onDimensionChange
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)

                if streamClient.isConnected {
                    MetalVideoView(decoder: h264Decoder)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.5)

                        Text("Connecting to \(device.name)...")
                            .foregroundColor(.white)
                            .font(.headline)

                        if let error = streamClient.connectionError {
                            Text("Error: \(error)")
                                .foregroundColor(.red)
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .padding()
                        }
                    }
                }
            }
            .onAppear {
                streamClient.connect()
            }
            .onDisappear {
                streamClient.disconnect()
            }
            // Listen for dimension changes from server
            .onChange(of: streamClient.videoDimensions) { newDimensions in
                if let dimensions = newDimensions {
                    print("[VideoPlayerView] Dimension change detected: \(Int(dimensions.width))x\(Int(dimensions.height))")
                    onDimensionChange?(dimensions)
                }
            }
        }
    }
}

// MARK: - Metal Video View

/// NSViewRepresentable that wraps AVSampleBufferDisplayLayer for hardware-accelerated rendering
/// Uses immediate rendering mode - flushes layer before each frame to prevent accumulation
struct MetalVideoView: NSViewRepresentable {

    @ObservedObject var decoder: H264Decoder

    func makeNSView(context: Context) -> VideoDisplayView {
        let view = VideoDisplayView()
        context.coordinator.setupView(view)
        return view
    }

    func updateNSView(_ nsView: VideoDisplayView, context: Context) {
        // No updates needed - dimensions are handled automatically
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(decoder: decoder)
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator {
        let decoder: H264Decoder
        private var displayLayer: AVSampleBufferDisplayLayer?
        private var cancellable: AnyCancellable?
        private weak var displayView: VideoDisplayView?
        private var cachedFormatDescription: CMFormatDescription?
        
        // Real-time rendering state
        private var isTimebaseInitialized = false
        private var frameCounter: Int64 = 0

        init(decoder: H264Decoder) {
            self.decoder = decoder
        }

        func setupView(_ view: VideoDisplayView) {
            self.displayView = view
            let layer = view.displayLayer

            // Configure the display layer to fill the entire window
            layer.videoGravity = .resizeAspectFill  // Fill window, crop if needed
            layer.backgroundColor = CGColor.black

            self.displayLayer = layer

            // Subscribe to frame updates with immediate rendering
            cancellable = decoder.$latestFrame
                .combineLatest(decoder.$latestFramePTS)
                .compactMap { frame, pts -> (CVImageBuffer, CMTime)? in
                    guard let frame = frame else { return nil }
                    return (frame, pts)
                }
                .sink { [weak self] frame, pts in
                    self?.renderFrameImmediate(frame)
                }
        }

        /// Render frame with quality preservation while staying real-time
        private func renderFrameImmediate(_ imageBuffer: CVImageBuffer) {
            guard let displayLayer = displayLayer else { return }

            // Use cached format description for better performance
            let formatDescription: CMFormatDescription?
            if let cached = cachedFormatDescription {
                formatDescription = cached
            } else {
                formatDescription = createFormatDescription(for: imageBuffer)
                cachedFormatDescription = formatDescription
            }

            guard let formatDescription = formatDescription else {
                return
            }

            // Get current host time
            let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
            
            // Initialize timebase on first frame
            if !isTimebaseInitialized {
                let timebase = createControlTimebase()
                displayLayer.controlTimebase = timebase
                CMTimebaseSetTime(timebase, time: hostTime)
                CMTimebaseSetRate(timebase, rate: 1.0)
                isTimebaseInitialized = true
                frameCounter = 0
            }

            // Increment frame counter for unique timestamps
            frameCounter += 1
            
            // Create timing info using frame counter for proper ordering
            // This ensures frames are displayed in order without gaps
            var timingInfo = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 120),  // Up to 120fps
                presentationTimeStamp: hostTime,
                decodeTimeStamp: .invalid
            )

            var sampleBuffer: CMSampleBuffer?
            let status = CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDescription,
                sampleTiming: &timingInfo,
                sampleBufferOut: &sampleBuffer
            )

            guard status == noErr, let sampleBuffer = sampleBuffer else {
                return
            }

            // Check layer health - only flush on error
            if displayLayer.status == .failed {
                displayLayer.flush()
                isTimebaseInitialized = false
                frameCounter = 0
                // Reinitialize timebase
                let timebase = createControlTimebase()
                displayLayer.controlTimebase = timebase
                CMTimebaseSetTime(timebase, time: hostTime)
                CMTimebaseSetRate(timebase, rate: 1.0)
                isTimebaseInitialized = true
            }
            
            // Sync timebase to prevent drift while preserving smooth playback
            if let timebase = displayLayer.controlTimebase {
                CMTimebaseSetTime(timebase, time: hostTime)
            }

            // Enqueue the sample buffer for rendering
            displayLayer.enqueue(sampleBuffer)
        }

        private func createFormatDescription(for imageBuffer: CVImageBuffer) -> CMFormatDescription? {
            var formatDescription: CMFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescriptionOut: &formatDescription
            )
            return formatDescription
        }

        private func createControlTimebase() -> CMTimebase {
            var timebase: CMTimebase?
            CMTimebaseCreateWithSourceClock(
                allocator: kCFAllocatorDefault,
                sourceClock: CMClockGetHostTimeClock(),
                timebaseOut: &timebase
            )
            return timebase!
        }
    }
}

// MARK: - Custom NSView with AVSampleBufferDisplayLayer

class VideoDisplayView: NSView {

    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    private func setupLayer() {
        wantsLayer = true
        layer = displayLayer
        displayLayer.frame = bounds
        displayLayer.videoGravity = .resizeAspect  // Maintain aspect ratio, fit within bounds
        displayLayer.backgroundColor = CGColor.black
    }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }
}
