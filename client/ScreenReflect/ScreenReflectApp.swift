//
//  ScreenReflectApp.swift
//  ScreenReflect
//
//  Main application entry point - MenuBarExtra utility.
//

import SwiftUI
import Combine
import CoreVideo
import os.log

/// Main application entry point
/// Manages menu bar interface and player windows
@main
struct ScreenReflectApp: App {

    // MARK: - Properties

    @StateObject private var browser = BonjourBrowser()
    @State private var playerWindows: [UUID: NSWindow] = [:]
    @State private var connectingDevices: Set<UUID> = []

    private let logger = Logger(subsystem: "com.screenreflect.ScreenReflect", category: "App")

    // MARK: - Scene

    var body: some Scene {
        MenuBarExtra("Screen Reflect", systemImage: "display") {
            ContentView(
                browser: browser,
                connectingDevices: connectingDevices,
                onDeviceSelected: { device in
                    connectingDevices.insert(device.id)
                    openPlayerWindow(for: device)
                }
            )
            .frame(width: 320, height: 450)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .menuBarExtraStyle(.window)
    }

    // MARK: - Window Management

    /// Opens or focuses a player window for the specified device
    private func openPlayerWindow(for device: DiscoveredDevice) {
        if let existingWindow = playerWindows[device.id] {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
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

        // Create the player view
        let playerView = VideoPlayerView(
            h264Decoder: h264Decoder,
            streamClient: streamClient,
            device: device
        )

        // Create hosting controller
        let hostingController = NSHostingController(rootView: playerView)

        // Create window - will resize to actual video dimensions once first frame arrives
        // Start with a reasonable default size
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = hostingController
        window.title = "Screen Reflect - \(device.name)"
        window.center()
        window.isReleasedWhenClosed = false

        // Set minimum size
        window.minSize = NSSize(width: 480, height: 360)

        // Observe connection to activate window and clear loading state
        var connectionObserver: AnyCancellable?
        connectionObserver = streamClient.$isConnected
            .filter { $0 }
            .first()
            .sink { [self] _ in
                DispatchQueue.main.async {
                    self.connectingDevices.remove(device.id)
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
                connectionObserver?.cancel()
            }

        // Observe first frame to resize window to actual video dimensions
        // Handles both portrait and landscape orientations automatically
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

        // Handle window close
        let windowDelegate = PlayerWindowDelegate {
            Task { @MainActor in
                streamClient.disconnect()
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

        // Show window immediately and activate
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
