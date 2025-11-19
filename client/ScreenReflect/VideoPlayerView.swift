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
    @StateObject private var orientationManager = OrientationManager()
    @State private var isHoveringWindow = false

    let device: DiscoveredDevice
    let onOrientationChange: ((CGSize) -> Void)?

    init(h264Decoder: H264Decoder, streamClient: StreamClient, device: DiscoveredDevice, onOrientationChange: ((CGSize) -> Void)? = nil) {
        self.h264Decoder = h264Decoder
        self.streamClient = streamClient
        self.device = device
        self.onOrientationChange = onOrientationChange
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)

                if streamClient.isConnected {
                    MetalVideoView(decoder: h264Decoder, orientationManager: orientationManager)
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

                // Orientation controls overlay
                if streamClient.isConnected {
                    OrientationControlsOverlay(orientationManager: orientationManager, isHoveringWindow: isHoveringWindow)
                }
            }
            .onAppear {
                streamClient.connect()
            }
            .onDisappear {
                streamClient.disconnect()
            }
            .onHover { hovering in
                // Detect hover over entire window
                isHoveringWindow = hovering
            }
            .onTapGesture {
                // Single click to close controls panel if open
                if orientationManager.showControls {
                    withAnimation(.spring(response: 0.3)) {
                        orientationManager.showControls = false
                    }
                }
            }
            // Track orientation changes and notify parent for window resizing
            .onChange(of: orientationManager.orientation) { _ in
                if let latestFrame = h264Decoder.latestFrame {
                    let videoSize = CGSize(
                        width: CVPixelBufferGetWidth(latestFrame),
                        height: CVPixelBufferGetHeight(latestFrame)
                    )
                    let displaySize = orientationManager.displaySize(for: videoSize)
                    onOrientationChange?(displaySize)
                }
            }
        }
    }
}

// MARK: - Orientation Controls Overlay

struct OrientationControlsOverlay: View {

    @ObservedObject var orientationManager: OrientationManager
    let isHoveringWindow: Bool

    var body: some View {
        VStack {
            HStack {
                Spacer()

                // Show controls only when hovering window or panel is open
                if isHoveringWindow || orientationManager.showControls {
                    if orientationManager.showControls {
                        // Full orientation control panel
                        HStack(spacing: 12) {
                            ForEach(OrientationManager.VideoOrientation.allCases) { mode in
                                Button(action: {
                                    withAnimation(.spring(response: 0.3)) {
                                        orientationManager.orientation = mode
                                    }
                                }) {
                                    VStack(spacing: 4) {
                                        Image(systemName: mode.icon)
                                            .font(.system(size: 18))
                                            .foregroundColor(orientationManager.orientation == mode ? .white : .gray)

                                        Text(mode.rawValue)
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundColor(orientationManager.orientation == mode ? .white : .gray)
                                    }
                                    .frame(width: 60, height: 50)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(orientationManager.orientation == mode ?
                                                  Color.blue.opacity(0.6) :
                                                  Color.black.opacity(0.3))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(orientationManager.orientation == mode ?
                                                   Color.blue :
                                                   Color.white.opacity(0.2),
                                                   lineWidth: 1.5)
                                    )
                                }
                                .buttonStyle(.plain)
                                .help(mode.description)
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(.ultraThinMaterial)
                                .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 4)
                        )
                        .transition(.scale.combined(with: .opacity))
                    } else {
                        // Compact floating button when hovering but panel is closed
                        Button(action: {
                            withAnimation(.spring(response: 0.3)) {
                                orientationManager.showControlsPanel()
                            }
                        }) {
                            Image(systemName: orientationManager.orientation.icon)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 36, height: 36)
                                .background(
                                    Circle()
                                        .fill(.ultraThinMaterial)
                                        .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 2)
                                )
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Change orientation")
                        .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .padding(.top, 12)
            .padding(.trailing, 12)

            Spacer()

            // Help text at bottom when controls are visible
            if orientationManager.showControls {
                HStack {
                    Spacer()
                    Text("Click outside to close")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                        )
                        .padding(.bottom, 12)
                        .padding(.trailing, 12)
                    Spacer()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3), value: orientationManager.showControls)
        .animation(.spring(response: 0.3), value: isHoveringWindow)
    }
}

// MARK: - Metal Video View

/// NSViewRepresentable that wraps AVSampleBufferDisplayLayer for hardware-accelerated rendering
struct MetalVideoView: NSViewRepresentable {

    @ObservedObject var decoder: H264Decoder
    @ObservedObject var orientationManager: OrientationManager

    func makeNSView(context: Context) -> VideoDisplayView {
        let view = VideoDisplayView()
        context.coordinator.setupView(view)
        return view
    }

    func updateNSView(_ nsView: VideoDisplayView, context: Context) {
        // Orientation changes only affect window size, not video rotation
        // No rotation applied to video content
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(decoder: decoder, orientationManager: orientationManager)
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator {
        let decoder: H264Decoder
        let orientationManager: OrientationManager
        private var displayLayer: AVSampleBufferDisplayLayer?
        private var cancellable: AnyCancellable?
        private var firstFramePTS: CMTime?
        private weak var displayView: VideoDisplayView?
        private var cachedFormatDescription: CMFormatDescription?

        init(decoder: H264Decoder, orientationManager: OrientationManager) {
            self.decoder = decoder
            self.orientationManager = orientationManager
        }

        func setupView(_ view: VideoDisplayView) {
            self.displayView = view
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

                // Initialize timebase on first frame
                let timebase = createControlTimebase()
                displayLayer.controlTimebase = timebase
                CMTimebaseSetTime(timebase, time: .zero)
                CMTimebaseSetRate(timebase, rate: 1.0)
            }

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
                return
            }

            // Check layer health and flush if needed
            if displayLayer.status == .failed {
                displayLayer.flush()
                if let timebase = displayLayer.controlTimebase {
                    CMTimebaseSetTime(timebase, time: normalizedPTS)
                    CMTimebaseSetRate(timebase, rate: 1.0)
                }
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

