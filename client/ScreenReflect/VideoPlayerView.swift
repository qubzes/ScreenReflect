//
//  VideoPlayerView.swift
//  ScreenReflect
//
//  Hardware-accelerated video rendering using AVSampleBufferDisplayLayer.
//  Optimized for smooth real-time playback.
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

/// NSViewRepresentable for hardware-accelerated rendering
struct MetalVideoView: NSViewRepresentable {

    @ObservedObject var decoder: H264Decoder

    func makeNSView(context: Context) -> VideoDisplayView {
        let view = VideoDisplayView()
        context.coordinator.setupView(view)
        return view
    }

    func updateNSView(_ nsView: VideoDisplayView, context: Context) {}

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
        
        // Timebase management
        private var controlTimebase: CMTimebase?
        private var isTimebaseInitialized = false

        init(decoder: H264Decoder) {
            self.decoder = decoder
        }

        func setupView(_ view: VideoDisplayView) {
            self.displayView = view
            let layer = view.displayLayer

            layer.videoGravity = .resizeAspectFill
            layer.backgroundColor = CGColor.black

            self.displayLayer = layer

            // Subscribe to frame updates
            cancellable = decoder.$latestFrame
                .compactMap { $0 }
                .sink { [weak self] frame in
                    self?.renderFrame(frame)
                }
        }

        /// Render frame to display layer
        private func renderFrame(_ imageBuffer: CVImageBuffer) {
            guard let displayLayer = displayLayer else { return }

            // Create format description (cached)
            let formatDescription: CMFormatDescription?
            if let cached = cachedFormatDescription {
                formatDescription = cached
            } else {
                formatDescription = createFormatDescription(for: imageBuffer)
                cachedFormatDescription = formatDescription
            }

            guard let formatDescription = formatDescription else { return }

            // Get current host time
            let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
            
            // Initialize or reset timebase if needed
            if !isTimebaseInitialized || displayLayer.status == .failed {
                resetTimebase(displayLayer: displayLayer, startTime: hostTime)
            }
            
            // Create timing info
            var timingInfo = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 60),  // 60fps
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

            guard status == noErr, let sampleBuffer = sampleBuffer else { return }

            // Enqueue for rendering
            displayLayer.enqueue(sampleBuffer)
        }
        
        private func resetTimebase(displayLayer: AVSampleBufferDisplayLayer, startTime: CMTime) {
            // Flush on error
            if displayLayer.status == .failed {
                displayLayer.flush()
                cachedFormatDescription = nil
            }
            
            // Create new timebase
            var timebase: CMTimebase?
            CMTimebaseCreateWithSourceClock(
                allocator: kCFAllocatorDefault,
                sourceClock: CMClockGetHostTimeClock(),
                timebaseOut: &timebase
            )
            
            if let timebase = timebase {
                CMTimebaseSetTime(timebase, time: startTime)
                CMTimebaseSetRate(timebase, rate: 1.0)
                displayLayer.controlTimebase = timebase
                self.controlTimebase = timebase
                isTimebaseInitialized = true
            }
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
    }
}

// MARK: - Custom NSView

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
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor.black
    }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }
}
