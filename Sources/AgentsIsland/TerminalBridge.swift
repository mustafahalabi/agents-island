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
        case .some(let app):
            osascript("tell application \"\(app)\" to activate")
        case nil:
            break
        }
    }

    /// Is the given terminal/editor app currently frontmost? Names are fuzzy —
    /// our detector says "iTerm"/"VS Code" while macOS reports "iTerm2"/"Code".
    static func isFrontmost(appNamed name: String?) -> Bool {
        guard let name, !name.isEmpty,
              let front = NSWorkspace.shared.frontmostApplication?.localizedName
        else { return false }
        let f = front.lowercased()
        let t = name.lowercased()
        if f.contains(t) || t.contains(f) { return true }
        if t == "vs code" { return f.contains("code") }
        return false
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
