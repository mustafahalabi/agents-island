import AppKit
import SwiftUI

/// Our own settings window. The SwiftUI Settings scene can't be opened
/// programmatically from an accessory app reliably, so we manage the
/// window ourselves.
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Agents Island Settings"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // Match the island's aesthetic (and the design reference).
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: SettingsView())
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
