//
//  ScreenReflectApp.swift
//  ScreenReflect
//
//  Main application entry point - MenuBarExtra utility.
//

import SwiftUI
import Combine
import CoreVideo

/// Main application entry point
/// Manages menu bar interface and player windows
@main
struct ScreenReflectApp: App {

    // MARK: - Properties

    @StateObject private var browser = BonjourBrowser()
    @State private var playerWindows: [UUID: NSWindow] = [:]
    @StateObject private var appState = AppState()

    // MARK: - Scene

    var body: some Scene {
        MenuBarExtra("Screen Reflect", systemImage: "display") {
            ContentView(
                browser: browser,
                appState: appState,
                onDeviceSelected: { device in
                    Task { @MainActor in
                        appState.setConnecting(device.id, isConnecting: true)
                        openPlayerWindow(for: device)
                    }
                }
            )
            .frame(width: 320, height: 450)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .menuBarExtraStyle(.window)
    }

    // MARK: - Window Management

    /// Opens or focuses a player window for the specified device
    @MainActor
    private func openPlayerWindow(for device: DiscoveredDevice) {
        // Check if window exists
        if let existingWindow = playerWindows[device.id] {
            // Window exists, bring it to front and try to reconnect
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            // Try to reconnect if not connected
            if let streamClient = getStreamClient(for: existingWindow) {
                if !streamClient.isConnected {
                    print("[ScreenReflectApp] Reconnecting to existing window")
                    streamClient.connect()
                }
            }
            return
        }

        // Create decoders
        let h264Decoder = H264Decoder()
        let aacDecoder = AACDecoder()

        // Create stream client
        let streamClient = StreamClient(
            device: device,
            h264Decoder: h264Decoder,
            aacDecoder: aacDecoder
        )

        // Create window - will resize to actual video dimensions once first frame arrives
        // Start with a reasonable default size
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        // Create the player view with dimension change callback
        let playerView = VideoPlayerView(
            h264Decoder: h264Decoder,
            streamClient: streamClient,
            device: device,
            onDimensionChange: { [weak window] newSize in
                guard let window = window else { return }
                Task { @MainActor in
                    self.resizeWindow(window, toVideoSize: newSize)
                }
            }
        )

        // Create hosting controller
        let hostingController = NSHostingController(rootView: playerView)

        window.contentViewController = hostingController
        window.title = "Screen Reflect - \(device.name)"
        window.center()
        window.isReleasedWhenClosed = false

        // Set minimum size
        window.minSize = NSSize(width: 480, height: 360)

        // Register stream client with AppState for connection tracking
        appState.registerStreamClient(device.id, streamClient)

        // Observe connection to show window when connected and close when disconnected
        var connectionObserver: AnyCancellable?
        var hasConnected = false
        connectionObserver = streamClient.$isConnected
            .sink { [weak window] isConnected in
                DispatchQueue.main.async {
                    if isConnected {
                        hasConnected = true
                        window?.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    } else if hasConnected {
                        // Connection lost - close window (AppState handles unregister)
                        window?.close()
                    }
                }
            }

        // Observe first frame to resize window to actual video dimensions
        var firstFrameObserver: AnyCancellable?
        firstFrameObserver = h264Decoder.$latestFrame
            .compactMap { $0 }
            .first()
            .sink { [self] imageBuffer in
                let videoWidth = CGFloat(CVPixelBufferGetWidth(imageBuffer))
                let videoHeight = CGFloat(CVPixelBufferGetHeight(imageBuffer))

                DispatchQueue.main.async {
                    self.resizeWindow(window, toVideoSize: NSSize(width: videoWidth, height: videoHeight))
                }

                firstFrameObserver?.cancel()
            }
        
        // Observe dimension changes from server (orientation changes)
        var dimensionObserver: AnyCancellable?
        dimensionObserver = streamClient.$videoDimensions
            .compactMap { $0 }
            .sink { [self] newDimensions in
                DispatchQueue.main.async {
                    print("[ScreenReflectApp] Dimension update: \(Int(newDimensions.width))x\(Int(newDimensions.height))")
                    self.resizeWindow(window, toVideoSize: newDimensions)
                }
            }

        // Handle window close
        let windowDelegate = PlayerWindowDelegate {
            Task { @MainActor in
                streamClient.disconnect()
                self.appState.unregisterStreamClient(device.id)
                self.playerWindows.removeValue(forKey: device.id)
            }
        }

        window.delegate = windowDelegate

        // Store window, delegate, and observers to keep them alive
        playerWindows[device.id] = window
        objc_setAssociatedObject(
            window,
            "windowDelegate",
            windowDelegate,
            .OBJC_ASSOCIATION_RETAIN
        )
        objc_setAssociatedObject(
            window,
            "connectionObserver",
            connectionObserver,
            .OBJC_ASSOCIATION_RETAIN
        )
        objc_setAssociatedObject(
            window,
            "firstFrameObserver",
            firstFrameObserver,
            .OBJC_ASSOCIATION_RETAIN
        )
        objc_setAssociatedObject(
            window,
            "dimensionObserver",
            dimensionObserver,
            .OBJC_ASSOCIATION_RETAIN
        )
        objc_setAssociatedObject(
            window,
            "streamClient",
            streamClient,
            .OBJC_ASSOCIATION_RETAIN
        )

        // Show window immediately and activate
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Helper to retrieve the StreamClient from a window
    private func getStreamClient(for window: NSWindow) -> StreamClient? {
        return objc_getAssociatedObject(window, "streamClient") as? StreamClient
    }

    /// Resizes window to match exact video dimensions from server
    /// Automatically handles portrait and landscape orientations
    private func resizeWindow(_ window: NSWindow, toVideoSize videoSize: NSSize) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        
        let currentFrame = window.frame
        let currentContentSize = window.contentView?.frame.size ?? .zero

        // Calculate window chrome (title bar and borders)
        let chromeWidth = currentFrame.width - currentContentSize.width
        let chromeHeight = currentFrame.height - currentContentSize.height

        // Get usable screen area (excluding menu bar and dock)
        let visibleFrame = screen.visibleFrame
        let maxWidth = visibleFrame.width - 40  // 20px margin on each side
        let maxHeight = visibleFrame.height - 40 // 20px margin top/bottom
        
        // Calculate target size, scaling down if needed
        var targetWidth = videoSize.width
        var targetHeight = videoSize.height
        
        // Scale down if video is larger than screen
        if targetWidth > maxWidth || targetHeight > maxHeight {
            let widthScale = maxWidth / targetWidth
            let heightScale = maxHeight / targetHeight
            let scale = min(widthScale, heightScale)
            
            targetWidth *= scale
            targetHeight *= scale
            
            print("[ScreenReflectApp] Scaling down video: \(videoSize.width)x\(videoSize.height) -> \(Int(targetWidth))x\(Int(targetHeight))")
        }
        
        // Calculate new frame size including chrome
        let newFrameWidth = targetWidth + chromeWidth
        let newFrameHeight = targetHeight + chromeHeight

        var newFrame = currentFrame
        newFrame.size = NSSize(width: newFrameWidth, height: newFrameHeight)

        // Lock aspect ratio to EXACT video dimensions (not scaled)
        let aspectRatio = videoSize.width / videoSize.height
        window.contentAspectRatio = NSSize(width: aspectRatio * 1000, height: 1000)

        // Animate resize and bring to front
        window.setFrame(newFrame, display: true, animate: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        print("[ScreenReflectApp] Window resized to: \(Int(newFrame.width))x\(Int(newFrame.height)) (content: \(Int(targetWidth))x\(Int(targetHeight)))")
    }
}

// MARK: - Window Delegate

class PlayerWindowDelegate: NSObject, NSWindowDelegate {

    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
