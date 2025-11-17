//
//  VideoPlayerView.swift
//  ScreenReflect
//
//  High-performance video rendering using AVSampleBufferDisplayLayer.
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
        }
    }
}

// MARK: - Metal Video View

/// NSViewRepresentable that wraps AVSampleBufferDisplayLayer for hardware-accelerated rendering
struct MetalVideoView: NSViewRepresentable {

    @ObservedObject var decoder: H264Decoder

    func makeNSView(context: Context) -> VideoDisplayView {
        let view = VideoDisplayView()
        context.coordinator.setupView(view)
        return view
    }

    func updateNSView(_ nsView: VideoDisplayView, context: Context) {
        // The coordinator handles frame updates via Combine
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
        private var firstFramePTS: CMTime?

        init(decoder: H264Decoder) {
            self.decoder = decoder
        }

        func setupView(_ view: VideoDisplayView) {
            let layer = view.displayLayer

            // Configure the display layer to maintain aspect ratio
            layer.videoGravity = .resizeAspect  // Maintain aspect ratio, fit within bounds
            layer.backgroundColor = CGColor.black

            self.displayLayer = layer

            // Subscribe to frame updates
            cancellable = decoder.$latestFrame
                .combineLatest(decoder.$latestFramePTS)
                .compactMap { frame, pts -> (CVImageBuffer, CMTime)? in
                    guard let frame = frame else { return nil }
                    return (frame, pts)
                }
                .sink { [weak self] frame, pts in
                    self?.renderFrame(frame, presentationTimeStamp: pts)
                }
        }

        private func renderFrame(_ imageBuffer: CVImageBuffer, presentationTimeStamp: CMTime) {
            guard let displayLayer = displayLayer else { return }

            // Normalize timestamps relative to the first frame
            let normalizedPTS: CMTime
            if let firstPTS = firstFramePTS {
                normalizedPTS = CMTimeSubtract(presentationTimeStamp, firstPTS)
            } else {
                firstFramePTS = presentationTimeStamp
                normalizedPTS = .zero
            }

            // Create format description for the image buffer
            guard let formatDescription = createFormatDescription(for: imageBuffer) else {
                print("[VideoPlayerView] Failed to create format description")
                return
            }

            // Create a sample buffer from the image buffer with proper timestamp
            var timingInfo = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 60),  // 60fps for smooth playback
                presentationTimeStamp: normalizedPTS,
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
                print("[VideoPlayerView] Failed to create sample buffer: \(status)")
                return
            }

            // Enqueue the sample buffer for rendering
            displayLayer.enqueue(sampleBuffer)

            // Request control time base if needed
            if displayLayer.status == .failed {
                displayLayer.flush()
            }

            // Start the layer if not already playing
            if displayLayer.controlTimebase == nil {
                let timebase = createControlTimebase()
                displayLayer.controlTimebase = timebase
                // Start timebase at zero (timestamps are normalized)
                CMTimebaseSetTime(timebase, time: .zero)
                CMTimebaseSetRate(timebase, rate: 1.0)
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

