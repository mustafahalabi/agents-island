import Foundation

/// Reads Codex CLI rollout files (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl)
/// to enrich Codex agents the same way ClaudeSessions does for Claude Code:
/// prompts, live activity, plan checklists, model, and real working/waiting
/// status from task events.
///
/// Codex has no pid registry, so pid → rollout mapping is two-step:
/// the rollout file the process holds open (lsof), falling back to matching
/// the rollout's recorded cwd against the process cwd.
enum CodexSessions {

    enum Phase: Equatable { case working, waiting, unknown }

    struct Info: Equatable {
        var lastPrompt: String?
        var activity: String?
        var model: String?
        var todos: [Todo] = []
        var phase: Phase = .unknown
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    private static var sessionsDir: String { home + "/.codex/sessions" }

    // MARK: - pid → rollout discovery

    private static var pidCache: [Int32: String] = [:]
    private static var recentCache: (at: Date, rollouts: [(path: String, cwd: String?, mtime: Date)])?
    private static var metaCwdCache: [String: String?] = [:]
    private static let lock = NSLock()

    /// Forget pid → rollout mappings for processes that are no longer running.
    ///
    /// Without this the cache only ever grew, and `fileExists` never expired an
    /// entry because rollout files are never deleted. Two things went wrong:
    ///
    /// - macOS recycles pids freely, so a *new* codex session landing on a
    ///   retired pid inherited the previous session's rollout and displayed its
    ///   prompt, activity, model and plan indefinitely.
    /// - `rolloutMatching` treats every cached value as already claimed, so a
    ///   rollout held by a long-dead pid stayed permanently reserved. A fresh
    ///   session in a directory that had an earlier one found its own rollout
    ///   taken and fell back to an older conversation.
    ///
    /// Called once per scan with the pids currently detected as codex.
    static func prune(livePids: Set<Int32>) {
        lock.lock()
        pidCache = RolloutAssignment.pruned(pidCache, livePids: livePids)
        lock.unlock()
    }

    /// Best-effort rollout path for a running codex process.
    static func rolloutPath(pid: Int32, cwd: String?) -> String? {
        lock.lock()
        if let cached = pidCache[pid], FileManager.default.fileExists(atPath: cached) {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let path = openRollout(pid: pid) ?? rolloutMatching(cwd: cwd)
        if let path {
            lock.lock()
            pidCache[pid] = path
            lock.unlock()
        }
        return path
    }

    /// Exact: the rollout jsonl the process has open for appending.
    private static func openRollout(pid: Int32) -> String? {
        let output = run("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-Fn"])
        for line in output.split(separator: "\n")
        where line.hasPrefix("n") && line.contains("/.codex/sessions/") && line.hasSuffix(".jsonl") {
            return String(line.dropFirst())
        }
        return nil
    }

    /// Fallback: most recent rollout whose session_meta cwd matches.
    ///
    /// `assigned` is only meaningful because `prune(livePids:)` keeps the cache
    /// to live processes — otherwise it accumulates rollouts claimed by dead
    /// pids and starves new sessions of their own.
    private static func rolloutMatching(cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        lock.lock()
        let assigned = Set(pidCache.values)
        lock.unlock()
        let candidates = recentRollouts().filter { $0.cwd == cwd }.map(\.path)
        return RolloutAssignment.select(candidates: candidates, assigned: assigned)
    }

    /// Rollouts modified in the last 48h, newest first. The directory walk is
    /// cached for 30s; each rollout's cwd (immutable session_meta) forever.
    private static func recentRollouts() -> [(path: String, cwd: String?, mtime: Date)] {
        lock.lock()
        if let cached = recentCache, Date().timeIntervalSince(cached.at) < 30 {
            lock.unlock()
            return cached.rollouts
        }
        lock.unlock()

        var found: [(path: String, cwd: String?, mtime: Date)] = []
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: URL(fileURLWithPath: sessionsDir),
                                          includingPropertiesForKeys: [.contentModificationDateKey],
                                          options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                guard Date().timeIntervalSince(mtime) < 48 * 3600 else { continue }
                found.append((url.path, metaCwd(path: url.path), mtime))
            }
        }
        found.sort { $0.mtime > $1.mtime }

        lock.lock()
        recentCache = (Date(), found)
        lock.unlock()
        return found
    }

    /// cwd from the first line (session_meta) of a rollout.
    private static func metaCwd(path: String) -> String? {
        lock.lock()
        if let cached = metaCwdCache[path] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var cwd: String?
        if let handle = FileHandle(forReadingAtPath: path),
           let data = try? handle.read(upToCount: 16 * 1024),
           let text = String(data: data, encoding: .utf8),
           let firstLine = text.split(separator: "\n").first,
           let obj = (try? JSONSerialization.jsonObject(with: Data(firstLine.utf8))) as? [String: Any] {
            let payload = obj["payload"] as? [String: Any] ?? obj
            cwd = payload["cwd"] as? String
            try? handle.close()
        }
        lock.lock()
        metaCwdCache[path] = cwd
        lock.unlock()
        return cwd
    }

    // MARK: - Rollout tail parsing

    private static var infoCache: [String: (mtime: Date, info: Info)] = [:]

    static func tailInfo(path: String) -> Info {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil

        lock.lock()
        if let mtime, let cached = infoCache[path], cached.mtime == mtime {
            lock.unlock()
            return cached.info
        }
        lock.unlock()

        var info = Info()
        var pendingCalls: [(id: String, description: String)] = []
        var resolvedCallIds = Set<String>()

        for obj in tailEntries(path: path, bytes: 256 * 1024) {
            guard let (type, payload) = record(obj) else { continue }
            switch type {
            case "turn_context":
                if let model = payload["model"] as? String, !model.isEmpty { info.model = model }
            case "response_item":
                handleItem(payload, info: &info, pending: &pendingCalls, resolved: &resolvedCallIds)
            case "event_msg":
                handleEvent(payload, info: &info)
            // Older flat format: response items at the top level.
            // "local_shell_call_output" was missing here, so shell results were
            // dropped before handleItem ever saw them.
            case "message", "function_call", "function_call_output",
                 "local_shell_call", "local_shell_call_output", "reasoning":
                var item = payload
                item["type"] = type
                handleItem(item, info: &info, pending: &pendingCalls, resolved: &resolvedCallIds)
            default:
                break
            }
        }

        // Unresolved tool call = still working, even without task events.
        let unresolved = pendingCalls.last { !resolvedCallIds.contains($0.id) }
        if info.phase == .unknown, unresolved != nil { info.phase = .working }
        if info.phase == .working {
            info.activity = unresolved?.description ?? "Thinking…"
        }

        if let mtime {
            lock.lock()
            infoCache[path] = (mtime, info)
            lock.unlock()
        }
        return info
    }

    private static func handleItem(_ item: [String: Any], info: inout Info,
                                   pending: inout [(id: String, description: String)],
                                   resolved: inout Set<String>) {
        switch item["type"] as? String {
        case "message":
            guard let role = item["role"] as? String else { return }
            if role == "user", let text = messageText(item), isRealUserText(text) {
                info.lastPrompt = text
            }
        case "function_call":
            let id = item["call_id"] as? String ?? item["id"] as? String ?? ""
            let name = item["name"] as? String ?? ""
            let arguments = item["arguments"] as? String ?? ""
            pending.append((id, describeCall(name: name, arguments: arguments)))
            if name == "update_plan", let todos = planTodos(arguments: arguments) {
                info.todos = todos
            }
        case "local_shell_call":
            let id = item["call_id"] as? String ?? item["id"] as? String ?? ""
            let action = item["action"] as? [String: Any]
            let command = (action?["command"] as? [String]) ?? []
            pending.append((id, describeShell(command)))
        default:
            // Any *_call_output resolves the call it names.
            //
            // Only "function_call_output" was handled, so shell results —
            // written as "local_shell_call_output" — fell through here and
            // every completed shell call stayed pending forever. Once the
            // task_complete event scrolled out of the 256KB window (a long turn
            // with large tool output), phase was .unknown, the unresolved call
            // forced it to .working, and the card showed "Running <an old
            // command>" while Codex sat idle at the prompt.
            //
            // Matching on the suffix rather than listing types also covers
            // custom tool outputs without needing another edit here.
            if let type = item["type"] as? String, type.hasSuffix("_call_output") {
                // The call side falls back to "id" when "call_id" is absent, so
                // the output side has to as well or the two never match.
                if let id = item["call_id"] as? String ?? item["id"] as? String {
                    resolved.insert(id)
                }
            }
        }
    }

    private static func handleEvent(_ event: [String: Any], info: inout Info) {
        switch event["type"] as? String {
        case "task_started":
            info.phase = .working
        case "task_complete", "turn_aborted", "error", "shutdown_complete":
            info.phase = .waiting
        case "user_message":
            if let text = event["message"] as? String, isRealUserText(text) {
                info.lastPrompt = text
            }
        default:
            break
        }
    }

    /// Recent plain-text conversation for the detail view, oldest first.
    static func recentMessages(path: String, limit: Int = 12) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        var index = 0

        func append(user: Bool, text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !user, let last = messages.last, !last.isUser {
                messages[messages.count - 1] = ChatMessage(id: last.id, isUser: false,
                                                           text: last.text + "\n\n" + trimmed)
            } else {
                messages.append(ChatMessage(id: index, isUser: user, text: trimmed))
                index += 1
            }
        }

        for obj in tailEntries(path: path, bytes: 384 * 1024) {
            guard let (type, payload) = record(obj) else { continue }
            var item: [String: Any]?
            if type == "response_item" { item = payload }
            if type == "message" { item = payload; item?["type"] = "message" }
            guard let item, item["type"] as? String == "message",
                  let role = item["role"] as? String,
                  let text = messageText(item) else { continue }
            if role == "user" {
                guard isRealUserText(text) else { continue }
                append(user: true, text: text)
            } else if role == "assistant" {
                append(user: false, text: text)
            }
        }
        return Array(messages.suffix(limit))
    }

    // MARK: - Helpers

    /// Both record shapes: {"type","payload":{…}} (current) and flat (older).
    private static func record(_ obj: [String: Any]) -> (String, [String: Any])? {
        guard let type = obj["type"] as? String else { return nil }
        if let payload = obj["payload"] as? [String: Any] { return (type, payload) }
        return (type, obj)
    }

    private static func messageText(_ item: [String: Any]) -> String? {
        guard let content = item["content"] as? [[String: Any]] else { return nil }
        let texts = content.compactMap { part -> String? in
            let type = part["type"] as? String
            guard type == "input_text" || type == "output_text" || type == "text" else { return nil }
            return part["text"] as? String
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// Codex injects environment context / instructions as user messages —
    /// they're XML-wrapped, not something the human typed.
    private static func isRealUserText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("<") && !trimmed.hasPrefix("# AGENTS.md")
    }

    private static func describeCall(name: String, arguments: String) -> String {
        switch name {
        case "shell", "exec_command", "container.exec":
            let obj = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
            if let command = obj?["command"] as? [String] { return describeShell(command) }
            if let command = obj?["command"] as? String { return describeShell([command]) }
            return "Running a command"
        case "apply_patch":
            // Patch text carries "*** Update File: path/to/file".
            if let range = arguments.range(of: #"\*\*\* (Update|Add|Delete) File: [^\\"\n]+"#,
                                           options: .regularExpression) {
                let line = String(arguments[range])
                let file = (line.components(separatedBy: ": ").last ?? "")
                let base = (file as NSString).lastPathComponent
                if !base.isEmpty { return "Editing \(base)" }
            }
            return "Editing files"
        case "update_plan":
            return "Updating the plan"
        case "web_search", "web_search_call":
            return "Searching the web"
        case "view_image":
            return "Viewing an image"
        default:
            return "Using \(name.replacingOccurrences(of: "_", with: " "))"
        }
    }

    private static func describeShell(_ command: [String]) -> String {
        // Commands usually arrive as ["bash", "-lc", "the real command"].
        var cmd = command.last ?? ""
        if command.count == 1 { cmd = command[0] }
        cmd = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return "Running a command" }
        let short = cmd.count > 48 ? String(cmd.prefix(47)) + "…" : cmd
        return "Running \(short)"
    }

    private static func planTodos(arguments: String) -> [Todo]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any],
              let plan = obj["plan"] as? [[String: Any]], !plan.isEmpty
        else { return nil }
        return plan.compactMap { step in
            guard let content = step["step"] as? String else { return nil }
            let raw = step["status"] as? String ?? "pending"
            let status = ["completed", "in_progress"].contains(raw) ? raw : "pending"
            return Todo(content: content, status: status)
        }
    }

    /// Parse the last `bytes` of a jsonl file (partial first line dropped).
    private static func tailEntries(path: String, bytes: Int) -> [[String: Any]] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return [] }

        // Lossy on purpose — the window can begin mid-character. See TailRead.
        let lines = TailRead.lines(data, dropsFirstLine: offset > 0)

        return lines.compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
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
