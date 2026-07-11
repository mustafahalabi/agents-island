import AppKit
import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService (macOS 13+). Only works when running
/// from a real .app bundle — silently no-ops from a bare `swift run` binary.
enum LoginItem {
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    static func set(enabled: Bool) {
        guard isAvailable else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("LoginItem: \(error.localizedDescription)")
        }
    }

    /// Register once on first launch so the island survives reboots by default.
    static func enableOnFirstLaunch() {
        let key = "didSetupLoginItem"
        guard isAvailable else { return }
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            set(enabled: true)
        } else if isEnabled {
            // Refresh the registration so it tracks the current bundle path
            // (e.g. after installing to /Applications).
            set(enabled: true)
        }
    }

    /// Copy the running bundle to /Applications and relaunch from there.
    /// Returns false if we're not running from a bundle or the copy failed.
    @discardableResult
    static func installToApplications() -> Bool {
        let source = Bundle.main.bundlePath
        guard source.hasSuffix(".app"), !source.hasPrefix("/Applications/") else { return false }
        let target = "/Applications/" + (source as NSString).lastPathComponent
        let fm = FileManager.default
        try? fm.removeItem(atPath: target)
        guard (try? fm.copyItem(atPath: source, toPath: target)) != nil else { return false }

        // Launch the copy; its single-instance guard terminates this one.
        let url = URL(fileURLWithPath: target)
        NSWorkspace.shared.openApplication(at: url,
                                           configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}
