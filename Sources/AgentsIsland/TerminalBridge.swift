import AppKit
import Foundation

/// Sends text to an agent's terminal session and jumps to it, targeting the
/// exact tab/pane via the process's tty. iTerm and Terminal have precise
/// AppleScript APIs; tmux uses send-keys; other terminals fall back to
/// activate + synthesized keystrokes (needs Accessibility permission).
enum TerminalBridge {

    @discardableResult
    static func send(text: String, to agent: AgentSession) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let dev = agent.tty.map { "/dev/\($0)" }

        switch agent.terminalApp {
        case "tmux":
            return tmuxSend(text: trimmed, tty: dev)
        case "iTerm":
            guard let dev else { return false }
            return osascript("""
            tell application "iTerm"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(dev)" then
                                tell s to write text "\(escaped(trimmed))"
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """)
        case "Terminal":
            guard let dev else { return false }
            return osascript("""
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(dev)" then
                            do script "\(escaped(trimmed))" in t
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """)
        case "WezTerm":
            guard let dev, let wez = weztermPath, let pane = weztermPaneId(dev: dev) else { return false }
            _ = run(wez, ["cli", "send-text", "--pane-id", pane, "--no-paste", trimmed + "\n"])
            return true
        case "kitty":
            guard let kitten = kittenPath, let win = kittyWindowId(pid: agent.id) else { return false }
            _ = run(kitten, ["@", "send-text", "--match", "id:\(win)", trimmed + "\n"])
            return true
        case .some(let app):
            // Generic: bring the terminal forward and type. Goes to the
            // frontmost window of that app — approximate but broad.
            return osascript("""
            tell application "\(app)" to activate
            delay 0.4
            tell application "System Events"
                keystroke "\(escaped(trimmed))"
                key code 36
            end tell
            """)
        case nil:
            return false
        }
    }

    static func jump(to agent: AgentSession) {
        let dev = agent.tty.map { "/dev/\($0)" }

        switch agent.terminalApp {
        case "tmux":
            if let dev { tmuxSelectPane(tty: dev) }
        case "iTerm":
            guard let dev else { return }
            osascript("""
            tell application "iTerm"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(dev)" then
                                select w
                                select t
                                select s
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """)
        case "Terminal":
            guard let dev else { return }
            osascript("""
            tell application "Terminal"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(dev)" then
                            set selected tab of w to t
                            set index of w to 1
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """)
        case "WezTerm":
            if let dev, let wez = weztermPath, let pane = weztermPaneId(dev: dev) {
                _ = run(wez, ["cli", "activate-pane", "--pane-id", pane])
            }
            osascript("tell application \"WezTerm\" to activate")
        case "kitty":
            if let kitten = kittenPath, let win = kittyWindowId(pid: agent.id) {
                _ = run(kitten, ["@", "focus-window", "--match", "id:\(win)"])
            }
            osascript("tell application \"kitty\" to activate")
        case .some(let app):
            osascript("tell application \"\(app)\" to activate")
        case nil:
            break
        }
    }

    /// Send a single raw key (no Enter) to the agent's session — used to
    /// answer Claude Code permission prompts ("1"/"2"/"3").
    @discardableResult
    static func sendKey(_ key: String, to agent: AgentSession) -> Bool {
        let dev = agent.tty.map { "/dev/\($0)" }

        switch agent.terminalApp {
        case "tmux":
            guard let tmux = tmuxPath, let pane = tmuxPane(tty: dev) else { return false }
            _ = run(tmux, ["send-keys", "-t", pane, "-l", key])
            return true
        case "iTerm":
            guard let dev else { return false }
            return osascript("""
            tell application "iTerm"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(dev)" then
                                tell s to write text "\(escaped(key))" newline NO
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """)
        case "WezTerm":
            guard let dev, let wez = weztermPath, let pane = weztermPaneId(dev: dev) else { return false }
            _ = run(wez, ["cli", "send-text", "--pane-id", pane, "--no-paste", key])
            return true
        case "kitty":
            guard let kitten = kittenPath, let win = kittyWindowId(pid: agent.id) else { return false }
            _ = run(kitten, ["@", "send-text", "--match", "id:\(win)", key])
            return true
        case .some:
            // Terminal.app & friends have no raw-key API; activate the right
            // window first, then synthesize the keystroke (needs Accessibility).
            jump(to: agent)
            return osascript("""
            delay 0.3
            tell application "System Events" to keystroke "\(escaped(key))"
            """)
        case nil:
            return false
        }
    }

    /// Is the given terminal/editor app currently frontmost? Names are fuzzy —
    /// our detector says "iTerm"/"VS Code" while macOS reports "iTerm2"/"Code".
    static func isFrontmost(appNamed name: String?) -> Bool {
        matches(appNamed: name, frontmost: NSWorkspace.shared.frontmostApplication?.localizedName)
    }

    /// The name-matching half, separated from NSWorkspace so it can be tested.
    ///
    /// A false positive here is not cosmetic: smart suppression uses this to
    /// decide you are already watching the agent's terminal, and silently drops
    /// the completion notification and auto-expand. The old rule matched any
    /// substring in either direction and special-cased "vs code" to any name
    /// containing "code" — so with an agent in VS Code and Xcode frontmost, it
    /// answered true and swallowed the notification.
    static func matches(appNamed name: String?, frontmost: String?) -> Bool {
        guard let name, !name.isEmpty, let frontmost, !frontmost.isEmpty else { return false }
        let f = frontmost.lowercased()
        let t = name.lowercased()

        if f == t { return true }

        // Known aliases where macOS's name differs from our detector's. Kept
        // explicit — substring matching is what caused the false positives.
        let aliases: [String: Set<String>] = [
            "vs code": ["code", "visual studio code", "code - insiders"],
            "iterm":   ["iterm2"],
            "cursor":  ["cursor"],
        ]
        if let known = aliases[t], known.contains(f) { return true }
        if let known = aliases[f], known.contains(t) { return true }

        // Fall back to a prefix relationship rather than "contains anywhere",
        // so "Code" no longer matches "Xcode". Guarded by a length floor so
        // very short names can't match half the Dock.
        guard min(f.count, t.count) >= 4 else { return false }
        return f.hasPrefix(t) || t.hasPrefix(f)
    }

    // MARK: - tmux

    private static var tmuxPath: String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func tmuxPane(tty: String?) -> String? {
        guard let tmux = tmuxPath, let tty else { return nil }
        let panes = run(tmux, ["list-panes", "-a", "-F", "#{pane_tty} #{pane_id}"])
        for line in panes.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, parts[0] == Substring(tty) { return String(parts[1]) }
        }
        return nil
    }

    private static func tmuxSend(text: String, tty: String?) -> Bool {
        guard let tmux = tmuxPath, let pane = tmuxPane(tty: tty) else { return false }
        _ = run(tmux, ["send-keys", "-t", pane, "-l", text])
        _ = run(tmux, ["send-keys", "-t", pane, "Enter"])
        return true
    }

    private static func tmuxSelectPane(tty: String) {
        guard let tmux = tmuxPath, let pane = tmuxPane(tty: tty) else { return }
        _ = run(tmux, ["switch-client", "-t", pane])
        _ = run(tmux, ["select-window", "-t", pane])
        _ = run(tmux, ["select-pane", "-t", pane])
    }

    // MARK: - WezTerm (wezterm cli — precise, matched by tty)

    private static var weztermPath: String? {
        ["/opt/homebrew/bin/wezterm", "/usr/local/bin/wezterm",
         "/Applications/WezTerm.app/Contents/MacOS/wezterm"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// pane_id of the WezTerm pane whose tty matches, e.g. "/dev/ttys003".
    private static func weztermPaneId(dev: String) -> String? {
        guard let wez = weztermPath else { return nil }
        let out = run(wez, ["cli", "list", "--format", "json"])
        guard let data = out.data(using: .utf8),
              let panes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        for pane in panes where pane["tty_name"] as? String == dev {
            if let id = pane["pane_id"] as? Int { return String(id) }
        }
        return nil
    }

    // MARK: - kitty (kitten @ — needs allow_remote_control; falls back to activate)

    private static var kittenPath: String? {
        ["/opt/homebrew/bin/kitten", "/usr/local/bin/kitten",
         "/Applications/kitty.app/Contents/MacOS/kitten"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// kitty window id whose foreground process is the agent (matched by pid).
    private static func kittyWindowId(pid: Int32) -> String? {
        guard let kitten = kittenPath else { return nil }
        let out = run(kitten, ["@", "ls"]) // empty if remote control is off
        guard let data = out.data(using: .utf8),
              let osWindows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        for osWindow in osWindows {
            for tab in (osWindow["tabs"] as? [[String: Any]] ?? []) {
                for window in (tab["windows"] as? [[String: Any]] ?? []) {
                    let fg = window["foreground_processes"] as? [[String: Any]] ?? []
                    let matches = fg.contains { ($0["pid"] as? Int).map(Int32.init) == pid }
                    if matches, let id = window["id"] as? Int { return String(id) }
                }
            }
        }
        return nil
    }

    // MARK: - Plumbing

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    @discardableResult
    private static func osascript(_ source: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
