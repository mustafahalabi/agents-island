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

    /// Live AskUserQuestion prompts, delivered by the PreToolUse hook the moment
    /// the question opens (the transcript only records it after it's answered).
    struct QuestionEntry: Equatable {
        let question: PendingQuestion
        let at: Date
    }
    @Published private(set) var questions: [Int32: QuestionEntry] = [:]

    func clearQuestion(pid: Int32) { questions[pid] = nil }

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

            let event = obj["hook_event_name"] as? String

            // AskUserQuestion lifecycle: PreToolUse fires the moment the prompt
            // opens (with the full questions/options JSON); PostToolUse when it's
            // answered. This is the only real-time source — the transcript gets
            // the tool_use only after the answer.
            if event == "PreToolUse" || event == "PostToolUse" {
                guard obj["tool_name"] as? String == "AskUserQuestion",
                      let sessionId = obj["session_id"] as? String else {
                    try? fm.removeItem(atPath: path); continue
                }
                guard let pid = registry.first(where: { $0.value.sessionId == sessionId })?.key else {
                    // Hook can beat the registry file — retry briefly, then drop.
                    if spoolFileAge(path) > 30 { try? fm.removeItem(atPath: path) }
                    continue
                }
                try? fm.removeItem(atPath: path)
                if event == "PreToolUse",
                   let input = obj["tool_input"] as? [String: Any],
                   let questionList = input["questions"] as? [[String: Any]],
                   let first = questionList.first {
                    let prompt = (first["question"] as? String)
                        ?? (first["header"] as? String) ?? "Choose an option"
                    let options = (first["options"] as? [[String: Any]] ?? [])
                        .compactMap { $0["label"] as? String }
                    if !options.isEmpty {
                        let entry = QuestionEntry(question: PendingQuestion(
                            prompt: prompt, options: options,
                            multiSelect: first["multiSelect"] as? Bool ?? false), at: Date())
                        DispatchQueue.main.async { self.questions[pid] = entry }
                    }
                } else if event == "PostToolUse" {
                    DispatchQueue.main.async { self.questions[pid] = nil }
                }
                continue
            }

            // PermissionRequest events carry the tool name directly; plain
            // Notification events only when the message mentions permission
            // ("waiting for your input" etc. is already the waiting status).
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
        guard hasPending || !questions.isEmpty else { return }
        let byPid = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Questions: answered in the terminal (agent busy again), session gone,
        // or stale → drop. The PostToolUse hook usually clears them first.
        for (pid, entry) in questions {
            let agent = byPid[pid]
            if agent == nil || agent?.status == .working
                || Date().timeIntervalSince(entry.at) > 30 * 60 {
                questions[pid] = nil
            }
        }

        guard hasPending else { return }
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
        //
        // Written to a dot-prefixed temp file and moved into place: the island
        // polls this directory once a second and drops anything that does not
        // parse, so a payload caught mid-write was a permission request that
        // silently never appeared. `mv` within one directory is atomic, and the
        // leading dot keeps the partial file out of the *.json scan.
        let script = """
        #!/bin/bash
        # Installed by Agents Island — forwards Claude Code notifications
        # (permission requests) to the island. Safe to delete.
        dir="$HOME/.claude/agents-island/notifications"
        mkdir -p "$dir"
        name="$(date +%s)-$$-$RANDOM.json"
        tmp="$dir/.$name.partial"
        cat > "$tmp" && mv -f "$tmp" "$dir/$name" || rm -f "$tmp"
        """
        guard fm.createFile(atPath: hookScriptPath, contents: Data(script.utf8),
                            attributes: [.posixPermissions: 0o755])
        else { return false }

        // Merge into ~/.claude/settings.json. That file is the user's, not
        // ours — it holds their permission rules, env and model settings — so
        // a settings file we cannot parse is a hard stop rather than something
        // to overwrite. Treating an unparseable file as an empty one silently
        // destroyed every setting in it.
        let root: [String: Any]
        switch HookSettings.load(data: fm.contents(atPath: claudeSettingsPath)) {
        case .missing:
            root = [:]
        case .parsed(let existing):
            root = existing
            backUpSettings()
        case .unreadable:
            NSLog("[AgentsIsland] refusing to install the hook: %@ is not valid JSON. "
                  + "Fix or move it, then try again.", claudeSettingsPath)
            return false
        }

        guard let out = HookSettings.serialize(
            HookSettings.merged(into: root, hookPath: hookScriptPath))
        else { return false }
        return fm.createFile(atPath: claudeSettingsPath, contents: out)
    }

    @discardableResult
    static func uninstallHook() -> Bool {
        let fm = FileManager.default
        let root: [String: Any]
        switch HookSettings.load(data: fm.contents(atPath: claudeSettingsPath)) {
        case .missing:
            try? fm.removeItem(atPath: hookScriptPath)
            return true                       // nothing registered anywhere
        case .parsed(let existing):
            root = existing
        case .unreadable:
            // Same reasoning as install: never rewrite a file we can't read.
            NSLog("[AgentsIsland] refusing to edit %@ — not valid JSON. "
                  + "Remove the agents-island hook entry by hand.", claudeSettingsPath)
            return false
        }

        guard let out = HookSettings.serialize(HookSettings.removed(from: root))
        else { return false }
        try? fm.removeItem(atPath: hookScriptPath)
        return fm.createFile(atPath: claudeSettingsPath, contents: out)
    }

    /// Keep a copy before rewriting. `copyItem` refuses to overwrite, so a
    /// backup from an earlier install would otherwise stick around forever and
    /// the pre-change state would be lost on the second run.
    private static func backUpSettings() {
        let fm = FileManager.default
        let backup = claudeSettingsPath + ".agents-island-backup"
        guard let data = fm.contents(atPath: claudeSettingsPath) else { return }
        try? data.write(to: URL(fileURLWithPath: backup))
    }
}

extension Notification.Name {
    /// Posted with the pid as `object` when a permission request arrives.
    static let approvalNeeded = Notification.Name("approvalNeeded")
}
