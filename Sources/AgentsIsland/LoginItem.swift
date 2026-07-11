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
        guard isAvailable, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(enabled: true)
    }
}
