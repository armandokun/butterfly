import AppKit

/// First launch from Downloads (or a zip): offer to move CTRL into /Applications, then relaunch from there.
enum Installer {
    static let target = URL(fileURLWithPath: "/Applications/Butterfly.app")

    /// Returns true when the app is relaunching from /Applications (caller should stop setup).
    @MainActor
    static func offerMoveToApplications() -> Bool {
        let here = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard here.pathExtension == "app",
              !here.path.hasPrefix("/Applications/"),
              !here.path.contains("/DerivedData/"),
              !here.path.contains("/Projects/") else { return false }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Butterfly to Applications?"
        alert.informativeText = "Butterfly works best from the Applications folder, so it can open at login and keep its permissions."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.icon = NSApp.applicationIconImage
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let fm = FileManager.default
        do {
            // Quit an older running copy, then replace it.
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            where app != .current { app.terminate() }
            if fm.fileExists(atPath: target.path) { try fm.trashItem(at: target, resultingItemURL: nil) }
            try fm.copyItem(at: here, to: target)
        } catch {
            let fail = NSAlert()
            fail.messageText = "Couldn't move Butterfly"
            fail.informativeText = "Drag Butterfly into the Applications folder yourself. (\(error.localizedDescription))"
            fail.runModal()
            return false
        }

        // Original copy: remove it unless macOS is running us from a read-only translocated path.
        if !here.path.contains("/AppTranslocation/") { try? fm.trashItem(at: here, resultingItemURL: nil) }

        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: target, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }
}
