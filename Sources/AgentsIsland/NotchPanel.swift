import AppKit
import SwiftUI

/// Physical notch (or fallback pill) dimensions for the target screen.
struct NotchMetrics: Equatable {
    let width: CGFloat
    let height: CGFloat
    let hasNotch: Bool

    static func detect(on screen: NSScreen) -> NotchMetrics {
        let defaults = UserDefaults.standard
        let dw = CGFloat(defaults.double(forKey: Pref.notchWidthOffset))
        let dh = CGFloat(defaults.double(forKey: Pref.notchHeightOffset))

        let inset = screen.safeAreaInsets.top
        if inset > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchMetrics(width: max(80, width + dw), height: max(20, inset + dh), hasNotch: true)
        }
        // No notch (external display / older Mac): draw a compact floating pill.
        return NotchMetrics(width: max(80, 148 + dw), height: max(20, 32 + dh), hasNotch: false)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// Borderless, non-activating panel pinned to the top-center of the chosen screen.
/// The window itself is large and transparent; the island draws inside it.
final class NotchPanel: NSPanel {
    static let panelSize = NSSize(width: 920, height: 860)
    private let monitor: AgentMonitor
    private var fullscreenTimer: Timer?

    init(monitor: AgentMonitor) {
        self.monitor = monitor
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true // key only for the keyboard switcher
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        repositionOnTargetScreen()
        startFullscreenWatch()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Intercept before SwiftUI so ScrollView etc. can't swallow the
    /// switcher's arrow keys / return / esc.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, SwitcherState.shared.handleKey(event) { return }
        super.sendEvent(event)
    }

    /// The screen chosen in settings; "auto" prefers the built-in (notched)
    /// display, falling back to the main screen.
    static func targetScreen() -> NSScreen? {
        let selection = UserDefaults.standard.string(forKey: Pref.displaySelection) ?? "auto"
        if selection.hasPrefix("id:"), let id = CGDirectDisplayID(selection.dropFirst(3)),
           let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
            return screen
        }
        return NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    func repositionOnTargetScreen() {
        guard let screen = Self.targetScreen() else { return }

        let notch = NotchMetrics.detect(on: screen)
        contentView = NSHostingView(rootView: IslandView(monitor: monitor, notch: notch))

        let frame = NSRect(
            x: screen.frame.midX - Self.panelSize.width / 2,
            y: screen.frame.maxY - Self.panelSize.height,
            width: Self.panelSize.width,
            height: Self.panelSize.height
        )
        setFrame(frame, display: true)
        updateFullscreenHide()
    }

    // MARK: - Hide in fullscreen

    /// Heuristic: on a fullscreen space the menu bar is hidden, so the
    /// screen's visibleFrame grows to the top edge. (Users who auto-hide the
    /// menu bar system-wide should keep this setting off.)
    private func startFullscreenWatch() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
        fullscreenTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.updateFullscreenHide()
        }
    }

    @objc private func spaceChanged() {
        updateFullscreenHide()
    }

    private func updateFullscreenHide() {
        guard UserDefaults.standard.bool(forKey: Pref.hideInFullscreen),
              let screen = Self.targetScreen()
        else {
            setIslandHidden(false)
            return
        }
        let menuBarHidden = screen.visibleFrame.maxY >= screen.frame.maxY - 1
        setIslandHidden(menuBarHidden)
    }

    private func setIslandHidden(_ hidden: Bool) {
        let alpha: CGFloat = hidden ? 0 : 1
        guard alphaValue != alpha else { return }
        alphaValue = alpha
        ignoresMouseEvents = hidden
        if hidden { SwitcherState.shared.end(collapse: true) }
    }
}
