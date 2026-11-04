import Foundation
import Sparkle

/// Sparkle: checks the GitHub releases feed (SUFeedURL) daily, downloads, verifies and installs updates.
/// Only inside Butterfly.app: a bare `swift build` binary has no Info.plist, and Sparkle would show an error.
@MainActor
enum Updates {
    static let bundled = Bundle.main.bundleURL.pathExtension == "app"
    static let controller = SPUStandardUpdaterController(startingUpdater: bundled, updaterDelegate: nil, userDriverDelegate: nil)
}
