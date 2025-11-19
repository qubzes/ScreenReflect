//
//  OrientationManager.swift
//  ScreenReflect
//
//  Manages display orientation state for video playback.
//

import SwiftUI
import Combine

/// Manages the orientation state for video display
@MainActor
class OrientationManager: ObservableObject {

    /// Current orientation mode
    @Published var orientation: VideoOrientation = .auto

    /// Whether the orientation control UI should be visible
    @Published var showControls: Bool = false

    /// Timer for auto-hiding controls
    private var hideControlsTimer: Timer?

    /// Available orientation modes
    enum VideoOrientation: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case portrait = "Portrait"
        case landscape = "Landscape"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .auto:
                return "rotate.3d"
            case .portrait:
                return "rectangle.portrait"
            case .landscape:
                return "rectangle"
            }
        }

        var description: String {
            switch self {
            case .auto:
                return "Match source orientation"
            case .portrait:
                return "Force portrait (rotate 90° if needed)"
            case .landscape:
                return "Force landscape (rotate -90° if needed)"
            }
        }
    }

    /// Toggle to the next orientation mode
    func toggleOrientation() {
        let allCases = VideoOrientation.allCases
        guard let currentIndex = allCases.firstIndex(of: orientation) else { return }
        let nextIndex = (currentIndex + 1) % allCases.count
        orientation = allCases[nextIndex]

        // Show controls briefly when toggling
        showControlsTemporarily()
    }

    /// Show controls and auto-hide after delay
    func showControlsTemporarily(duration: TimeInterval = 2.0) {
        showControls = true

        hideControlsTimer?.invalidate()
        hideControlsTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.showControls = false
        }
    }

    /// Manually show controls (stays visible until user hides or timeout)
    func showControlsPanel() {
        showControlsTemporarily(duration: 3.0)
    }

    /// Calculate the window size based on orientation preference
    /// This doesn't rotate the video, only changes the window dimensions
    func displaySize(for videoSize: CGSize) -> CGSize {
        let isSourcePortrait = videoSize.height > videoSize.width

        switch orientation {
        case .auto:
            // Keep original dimensions
            return videoSize

        case .portrait:
            // Force portrait window (tall)
            if isSourcePortrait {
                // Already portrait, keep as is
                return videoSize
            } else {
                // Source is landscape, swap dimensions for portrait window
                return CGSize(width: videoSize.height, height: videoSize.width)
            }

        case .landscape:
            // Force landscape window (wide)
            if isSourcePortrait {
                // Source is portrait, swap dimensions for landscape window
                return CGSize(width: videoSize.height, height: videoSize.width)
            } else {
                // Already landscape, keep as is
                return videoSize
            }
        }
    }
}
