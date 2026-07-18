import Foundation

/// Permission approvals from the island.
///
/// A Claude Code **Notification hook** (installed via Settings → Integrations)
/// writes each notification's JSON to ~/.claude/agents-island/notifications/.
/// This center watches that spool, matches "needs your permission" events to
/// running sessions, and answers the terminal prompt by sending the digit
/// keys: 1 = Yes, 2 = Yes for this session, 3 = No. The hook never blocks
/// Claude — the terminal prompt stays usable in parallel.
final class ApprovalCenter: ObservableObject {
    static let shared = ApprovalCenter()

    struct Approval: Equatable {
        let sessionId: String
        let message: String        // "Claude needs your permission to use Bash"
        let toolName: String?
        let at: Date
        var activityAtCreate: String?
    }

    enum Action {
        case approve, alwaysAllow, deny

        var key: String {
            switch self {
            case .approve: return "1"
            case .alwaysAllow: return "2"
            case .deny: return "3"
            }
        }
    }

    @Published private(set) var pending: [Int32: Approval] = [:]
    var hasPending: Bool { !pending.isEmpty }

    private var timer: Timer?
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let supportDir = home + "/.claude/agents-island"
    static let spoolDir = supportDir + "/notifications"
    static let hookScriptPath = supportDir + "/notify-hook.sh"

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.drainSpool()
        }
    }

    // MARK: - Spool

    private func drainSpool() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: Self.spoolDir), !files.isEmpty
        else { return }

        let registry = ClaudeSessions.sessionsByPid()
        for file in files.sorted() where file.hasSuffix(".json") {
            let path = Self.spoolDir + "/" + file
            guard let data = fm.contents(atPath: path),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { try? fm.removeItem(atPath: path); continue } // unparseable → drop

            // PermissionRequest events carry the tool name directly; plain
            // Notification events only when the message mentions permission
            // ("waiting for your input" etc. is already the waiting status).
            let event = obj["hook_event_name"] as? String
            let message = obj["message"] as? String ?? ""
            var tool: String?
            if event == "PermissionRequest" {
                tool = obj["tool_name"] as? String
            } else if message.localizedCaseInsensitiveContains("permission") {
                tool = toolName(from: message)
            } else {
                try? fm.removeItem(atPath: path); continue // not a permission event
            }
            guard let sessionId = obj["session_id"] as? String else {
                try? fm.removeItem(atPath: path); continue
            }
            guard let pid = registry.first(where: { $0.value.sessionId == sessionId })?.key else {
                // The hook can beat Claude's own session-registry file to disk.
                // Keep the event so a later tick can match it once the pid is
                // known — but don't spool a never-matching event forever.
                if spoolFileAge(path) > 30 { try? fm.removeItem(atPath: path) }
                continue
            }
            try? fm.removeItem(atPath: path) // matched → consume
            let agent = AgentMonitor.shared.agents.first { $0.id == pid }
            let toolName = tool
            DispatchQueue.main.async {
                self.pending[pid] = Approval(
                    sessionId: sessionId,
                    message: message,
                    toolName: toolName,
                    at: Date(),
                    activityAtCreate: agent?.activity
                )
                HotKeyCenter.shared.update()
                NotificationCenter.default.post(name: .approvalNeeded, object: pid)
            }
        }
    }

    /// Seconds since a spool file was written (greatestFiniteMagnitude if unknown).
    private func spoolFileAge(_ path: String) -> TimeInterval {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        return mtime.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
    }

    /// "Claude needs your permission to use Bash" → "Bash"
    private func toolName(from message: String) -> String? {
        guard let range = message.range(of: "to use ") else { return nil }
        let tail = message[range.upperBound...]
        let name = tail.split(separator: " ").first.map(String.init)
        return name?.trimmingCharacters(in: CharacterSet(charactersIn: ".,:"))
    }

    // MARK: - Responding

    func respond(pid: Int32, action: Action) {
        guard pending[pid] != nil,
              let agent = AgentMonitor.shared.agents.first(where: { $0.id == pid })
        else {
            pending[pid] = nil
            return
        }
        pending[pid] = nil
        HotKeyCenter.shared.update()
        DispatchQueue.global(qos: .userInitiated).async {
            TerminalBridge.sendKey(action.key, to: agent)
        }
    }

    /// Hotkey path: acts on the most recent pending approval.
    func respondToNewest(action: Action) {
        guard let pid = pending.max(by: { $0.value.at < $1.value.at })?.key else { return }
        respond(pid: pid, action: action)
    }

    /// Called after each monitor scan: drop approvals answered in the
    /// terminal (activity moved on / turn ended) or gone stale.
    func sync(agents: [AgentSession]) {
        guard hasPending else { return }
        let byPid = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        var changed = false
        for (pid, approval) in pending {
            let agent = byPid[pid]
            let answeredInTerminal = agent.map {
                $0.status == .waiting || $0.activity != approval.activityAtCreate
            } ?? true
            if answeredInTerminal || Date().timeIntervalSince(approval.at) > 10 * 60 {
                pending[pid] = nil
                changed = true
            }
        }
        if changed { HotKeyCenter.shared.update() }
    }

    // MARK: - Hook installation (Settings → Integrations)

    /// Claude Code settings file the hook is registered in.
    /// (Overridable so tests never touch the real file.)
    static var settingsPathOverride: String?
    private static var claudeSettingsPath: String {
        settingsPathOverride ?? home + "/.claude/settings.json"
    }

    static var hookInstalled: Bool {
        guard let data = FileManager.default.contents(atPath: claudeSettingsPath),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("agents-island/notify-hook.sh")
    }

    @discardableResult
    static func installHook() -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: spoolDir, withIntermediateDirectories: true)

        // BSD date has no %N — epoch + pid + RANDOM is unique enough.
        let script = """
        #!/bin/bash
        # Installed by Agents Island — forwards Claude Code notifications
        # (permission requests) to the island. Safe to delete.
        dir="$HOME/.claude/agents-island/notifications"
        mkdir -p "$dir"
        cat > "$dir/$(date +%s)-$$-$RANDOM.json"
        """
        guard fm.createFile(atPath: hookScriptPath, contents: Data(script.utf8),
                            attributes: [.posixPermissions: 0o755])
        else { return false }

        // Merge into ~/.claude/settings.json — PermissionRequest (rich, has
        // tool_name) plus Notification (fallback on older Claude versions).
        var root: [String: Any] = [:]
        if let data = fm.contents(atPath: claudeSettingsPath) {
            root = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
            try? fm.copyItem(atPath: claudeSettingsPath,
                             toPath: claudeSettingsPath + ".agents-island-backup")
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for eventName in ["PermissionRequest", "Notification"] {
            var entries = hooks[eventName] as? [[String: Any]] ?? []
            let alreadyThere = entries.contains { entry in
                ((entry["hooks"] as? [[String: Any]]) ?? [])
                    .contains { ($0["command"] as? String)?.contains("agents-island") == true }
            }
            if !alreadyThere {
                entries.append([
                    "hooks": [["type": "command", "command": hookScriptPath, "async": true]]
                ])
            }
            hooks[eventName] = entries
        }
        root["hooks"] = hooks

        guard let out = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return false }
        return fm.createFile(atPath: claudeSettingsPath, contents: out)
    }

    @discardableResult
    static func uninstallHook() -> Bool {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: claudeSettingsPath),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any]
        else { return true }

        for eventName in ["PermissionRequest", "Notification"] {
            guard var entries = hooks[eventName] as? [[String: Any]] else { continue }
            entries.removeAll { entry in
                ((entry["hooks"] as? [[String: Any]]) ?? [])
                    .contains { ($0["command"] as? String)?.contains("agents-island") == true }
            }
            if entries.isEmpty {
                hooks.removeValue(forKey: eventName)
            } else {
                hooks[eventName] = entries
            }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }

        guard let out = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return false }
        try? fm.removeItem(atPath: hookScriptPath)
        return fm.createFile(atPath: claudeSettingsPath, contents: out)
    }
}

extension Notification.Name {
    /// Posted with the pid as `object` when a permission request arrives.
    static let approvalNeeded = Notification.Name("approvalNeeded")
}
