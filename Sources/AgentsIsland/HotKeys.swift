import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon's RegisterEventHotKey — works from an accessory
/// app with no Accessibility permission. ⌘/⌃/⌥ + G opens the session
/// switcher; +Shift cycles backwards.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    private static let forwardId: UInt32 = 1
    private static let backwardId: UInt32 = 2

    /// (Re-)register hotkeys from current preferences.
    func update() {
        unregisterAll()
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Pref.shortcutsEnabled) else { return }

        installHandlerIfNeeded()
        let modifiers = Self.carbonModifiers(defaults.string(forKey: Pref.shortcutModifier) ?? "control")
        register(keyCode: UInt32(kVK_ANSI_G), modifiers: modifiers, id: Self.forwardId)
        if defaults.bool(forKey: Pref.reverseSwitcher) {
            register(keyCode: UInt32(kVK_ANSI_G), modifiers: modifiers | UInt32(shiftKey), id: Self.backwardId)
        }
    }

    static func carbonModifiers(_ name: String) -> UInt32 {
        switch name {
        case "option": return UInt32(optionKey)
        case "command": return UInt32(cmdKey)
        default: return UInt32(controlKey)
        }
    }

    static func modifierSymbol(_ name: String) -> String {
        switch name {
        case "option": return "⌥"
        case "command": return "⌘"
        default: return "⌃"
        }
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hotKeyId = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyId)
            DispatchQueue.main.async {
                SwitcherState.shared.advance(by: hotKeyId.id == HotKeyCenter.backwardId ? -1 : 1)
            }
            return noErr
        }, 1, &eventType, nil, &handler)
    }

    private func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) {
        var ref: EventHotKeyRef?
        let hotKeyId = EventHotKeyID(signature: OSType(0x4149_4C44) /* "AILD" */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyId,
                                         GetEventDispatcherTarget(), 0, &ref)
        if status == noErr, let ref { hotKeys.append(ref) }
    }

    private func unregisterAll() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
    }
}

/// Keyboard-driven session switcher: hotkey opens the island in keyboard
/// mode, repeated presses / arrow keys cycle through sessions, ⏎ or mod+T
/// jumps to the selected session's terminal, esc dismisses.
final class SwitcherState: ObservableObject {
    static let shared = SwitcherState()

    @Published private(set) var active = false
    @Published private(set) var index = 0

    weak var panel: NotchPanel?

    private var visibleAgents: [AgentSession] {
        let maxVisible = max(1, UserDefaults.standard.integer(forKey: Pref.maxVisibleSessions))
        return Array(AgentMonitor.shared.agents.prefix(maxVisible))
    }

    /// Hotkey entry point: open the switcher, or cycle when already open.
    func advance(by delta: Int) {
        // Never grab the keyboard while the island is hidden (fullscreen).
        if let panel, panel.alphaValue < 0.5 { return }
        let agents = visibleAgents
        guard !agents.isEmpty else { return }
        if active {
            index = ((index + delta) % agents.count + agents.count) % agents.count
        } else {
            active = true
            index = delta >= 0 ? 0 : agents.count - 1
            panel?.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .islandExpand, object: "switcher")
        }
    }

    func confirm() {
        let agents = visibleAgents
        if agents.indices.contains(index) {
            TerminalBridge.jump(to: agents[index])
        }
        end(collapse: true)
    }

    func end(collapse: Bool) {
        guard active else { return }
        active = false
        // Drop key status without hiding: re-adding the panel unkeyed hands
        // keyboard focus back to the previously active app.
        panel?.orderOut(nil)
        panel?.orderFrontRegardless()
        if collapse {
            NotificationCenter.default.post(name: .islandCollapse, object: nil)
        }
    }

    /// Key events routed from the panel while it is key. Returns true when handled.
    func handleKey(_ event: NSEvent) -> Bool {
        guard active, UserDefaults.standard.bool(forKey: Pref.shortcutsEnabled) else { return false }
        switch Int(event.keyCode) {
        case kVK_DownArrow:
            advance(by: 1); return true
        case kVK_UpArrow:
            advance(by: -1); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            confirm(); return true
        case kVK_Escape:
            end(collapse: true); return true
        case kVK_ANSI_T:
            confirm(); return true
        case kVK_ANSI_G where event.modifierFlags.contains(.control)
            || event.modifierFlags.contains(.option)
            || event.modifierFlags.contains(.command):
            // The Carbon hotkey normally swallows this; belt and suspenders.
            advance(by: event.modifierFlags.contains(.shift) ? -1 : 1); return true
        default:
            return false
        }
    }
}
