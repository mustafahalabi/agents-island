import Foundation

/// Reads Grok CLI's session store (~/.grok) to enrich Grok agents the same way
/// ClaudeSessions/CodexSessions do: real working/waiting status from turn
/// events, prompts, live activity, title, model, and todos.
///
/// Without this, Grok fell back to the CPU heuristic — and Grok's turn shape
/// (server-side "Thought for 1.8s" at ~0% CPU, then a tool call spike) flapped
/// working ↔ idle on every thinking step, firing a completion notification and
/// sound each time.
///
/// Store layout:
///   ~/.grok/active_sessions.json                     [{session_id, pid, cwd}]
///   ~/.grok/sessions/<percent-encoded cwd>/<session_id>/
///     events.jsonl        turn_started / turn_ended, phase_changed,
///                         tool_started / tool_completed, permission_* …
///     summary.json        generated_title, current_model_id
///     chat_history.jsonl  user / assistant / tool_result records
enum GrokSessions {

    enum Phase: Equatable { case working, waiting, unknown }

    struct Info: Equatable {
        var title: String?
        var lastPrompt: String?
        var lastMessage: String?
        var activity: String?
        var model: String?
        var todos: [Todo] = []
        var phase: Phase = .unknown
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    private static var sessionsRoot: String { home + "/.grok/sessions" }
    private static var registryPath: String { home + "/.grok/active_sessions.json" }

    private static let lock = NSLock()

    // MARK: - pid → session directory

    private struct RegistryEntry {
        let pid: Int32
        let sessionId: String
        let cwd: String
    }

    private static var registryCache: (at: Date, entries: [RegistryEntry])?

    /// Best-effort session directory for a running grok process: the pid
    /// registry first, then the newest session recorded for the same cwd.
    static func sessionDir(pid: Int32, cwd: String?) -> String? {
        let fm = FileManager.default
        if let entry = registry().first(where: { $0.pid == pid }) {
            let direct = sessionsRoot + "/" + encodedProjectDir(entry.cwd) + "/" + entry.sessionId
            if fm.fileExists(atPath: direct) { return direct }
            // Grok's percent-encoding may diverge from ours on unusual paths —
            // fall back to matching project dirs by their decoded names.
            if let project = projectDir(cwd: entry.cwd) {
                let scanned = project + "/" + entry.sessionId
                if fm.fileExists(atPath: scanned) { return scanned }
            }
        }
        guard let cwd, let project = projectDir(cwd: cwd) else { return nil }
        return newestSession(in: project)
    }

    private static func registry() -> [RegistryEntry] {
        lock.lock()
        if let cached = registryCache, Date().timeIntervalSince(cached.at) < 5 {
            lock.unlock()
            return cached.entries
        }
        lock.unlock()

        var entries: [RegistryEntry] = []
        if let data = FileManager.default.contents(atPath: registryPath),
           let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            for obj in list {
                guard let pid = obj["pid"] as? Int32 ?? (obj["pid"] as? Int).map(Int32.init),
                      let sessionId = obj["session_id"] as? String,
                      let cwd = obj["cwd"] as? String else { continue }
                entries.append(RegistryEntry(pid: pid, sessionId: sessionId, cwd: cwd))
            }
        }
        lock.lock()
        registryCache = (Date(), entries)
        lock.unlock()
        return entries
    }

    /// Grok names project dirs by percent-encoding the cwd ("/" → "%2F").
    private static func encodedProjectDir(_ cwd: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return cwd.addingPercentEncoding(withAllowedCharacters: unreserved) ?? cwd
    }

    /// Project dir whose decoded name equals the cwd — robust to any encoding.
    private static func projectDir(cwd: String) -> String? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: sessionsRoot) else { return nil }
        for name in names where name.removingPercentEncoding == cwd {
            return sessionsRoot + "/" + name
        }
        return nil
    }

    /// Session subdir with the freshest events.jsonl.
    private static func newestSession(in projectDir: String) -> String? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: projectDir) else { return nil }
        var best: (path: String, mtime: Date)?
        for name in names {
            let dir = projectDir + "/" + name
            guard let attrs = try? fm.attributesOfItem(atPath: dir + "/events.jsonl"),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if best == nil || mtime > best!.mtime { best = (dir, mtime) }
        }
        return best?.path
    }

    // MARK: - Session info

    private static var infoCache: [String: (stamp: String, info: Info)] = [:]

    static func info(dir: String) -> Info {
        let eventsPath = dir + "/events.jsonl"
        let chatPath = dir + "/chat_history.jsonl"
        let summaryPath = dir + "/summary.json"

        func mtime(_ path: String) -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
        }
        let stamp = [eventsPath, chatPath, summaryPath]
            .map { mtime($0)?.timeIntervalSince1970.description ?? "-" }
            .joined(separator: "|")

        lock.lock()
        if let cached = infoCache[dir], cached.stamp == stamp {
            lock.unlock()
            return cached.info
        }
        lock.unlock()

        var info = Info()
        parseSummary(path: summaryPath, into: &info)
        parseChat(path: chatPath, into: &info)
        parseEvents(path: eventsPath, into: &info)

        // A crashed CLI leaves the last turn permanently "started". If the
        // event stream has been silent for 30 minutes, stop vouching for it.
        if info.phase == .working, let last = mtime(eventsPath),
           Date().timeIntervalSince(last) > 30 * 60 {
            info.phase = .unknown
            info.activity = nil
        }

        lock.lock()
        infoCache[dir] = (stamp, info)
        lock.unlock()
        return info
    }

    // MARK: summary.json — title + model

    private static func parseSummary(path: String, into info: inout Info) {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        info.title = (obj["generated_title"] as? String) ?? (obj["session_summary"] as? String)
        info.model = obj["current_model_id"] as? String
    }

    // MARK: chat_history.jsonl — prompts, last reply, todos, in-flight tool

    /// The last assistant tool call whose result hasn't landed, for activity.
    private struct ChatTail {
        var unresolvedCall: (name: String, arguments: String)?
    }

    private static func parseChat(path: String, into info: inout Info) {
        var pending: [(id: String, name: String, arguments: String)] = []
        var resolved = Set<String>()

        for obj in tailEntries(path: path, bytes: 256 * 1024) {
            switch obj["type"] as? String {
            case "user":
                if let text = userText(obj) { info.lastPrompt = text }
            case "assistant":
                if let text = obj["content"] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    info.lastMessage = text
                }
                for call in obj["tool_calls"] as? [[String: Any]] ?? [] {
                    guard let name = call["name"] as? String else { continue }
                    let id = call["id"] as? String ?? ""
                    let arguments = call["arguments"] as? String ?? ""
                    pending.append((id, name, arguments))
                    if name == "todo_write", let todos = todoList(arguments: arguments) {
                        info.todos = todos
                    }
                }
            case "tool_result":
                if let id = obj["tool_call_id"] as? String { resolved.insert(id) }
            default:
                break
            }
        }

        if let call = pending.last(where: { !resolved.contains($0.id) }) {
            info.activity = describeCall(name: call.name, arguments: call.arguments)
        }
    }

    /// Grok wraps what the human typed in <user_query> tags; other user-role
    /// records are injected context and start with a different tag.
    static func userText(_ obj: [String: Any]) -> String? {
        guard let content = obj["content"] as? [[String: Any]] else { return nil }
        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = trimmed.range(of: "<user_query>"),
           let end = trimmed.range(of: "</user_query>", options: .backwards),
           start.upperBound <= end.lowerBound {
            let inner = trimmed[start.upperBound..<end.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return inner.isEmpty ? nil : inner
        }
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        return trimmed
    }

    private static func todoList(arguments: String) -> [Todo]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any],
              let todos = obj["todos"] as? [[String: Any]], !todos.isEmpty
        else { return nil }
        return todos.compactMap { entry in
            guard let content = entry["content"] as? String else { return nil }
            let raw = entry["status"] as? String ?? "pending"
            let status = ["completed", "in_progress"].contains(raw) ? raw : "pending"
            return Todo(content: content, status: status)
        }
    }

    private static func describeCall(name: String, arguments: String) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
        func base(_ key: String) -> String? {
            guard let path = args?[key] as? String, !path.isEmpty else { return nil }
            return (path as NSString).lastPathComponent
        }
        switch name {
        case "run_terminal_command":
            if let cmd = (args?["command"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !cmd.isEmpty {
                let short = cmd.count > 48 ? String(cmd.prefix(47)) + "…" : cmd
                return "Running \(short)"
            }
            return "Running a command"
        case "write", "search_replace":
            if let file = base("file_path") { return "Editing \(file)" }
            return "Editing files"
        case "read_file":
            if let file = base("target_file") { return "Reading \(file)" }
            return "Reading a file"
        case "list_dir":
            return "Listing files"
        case "grep", "search_tool":
            return "Searching the code"
        case "web_search", "web_fetch":
            return "Searching the web"
        case "spawn_subagent":
            return "Running a subagent"
        case "get_command_or_subagent_output":
            return "Waiting on a background task"
        case "todo_write":
            return "Updating the plan"
        case "use_tool":
            if let tool = args?["tool_name"] as? String {
                return "Using \(tool.replacingOccurrences(of: "_", with: " "))"
            }
            return "Using a tool"
        default:
            return "Using \(name.replacingOccurrences(of: "_", with: " "))"
        }
    }

    // MARK: events.jsonl — the phase

    /// The state a stream of turn events reduces to. Shared by the local
    /// tail reader and RemoteMonitor's over-SSH tails.
    struct EventState: Equatable {
        var phase: Phase = .unknown
        var streaming: String?      // "Thinking…" / "Replying…" while working
        var toolRunning = false
    }

    /// Fold event records (oldest first) into a phase.
    static func reduceEvents(_ events: [[String: Any]]) -> EventState {
        var state = EventState()
        var sawTurnActivity = false
        var permissionPending = false

        for obj in events {
            guard let type = obj["type"] as? String else { continue }
            switch type {
            case "turn_started":
                state.phase = .working
                state.streaming = nil
                state.toolRunning = false
                permissionPending = false
            case "turn_ended":
                state.phase = .waiting
                state.streaming = nil
                state.toolRunning = false
                permissionPending = false
            case "phase_changed":
                sawTurnActivity = true
                switch obj["phase"] as? String {
                case "waiting_for_model", "streaming_reasoning":
                    state.streaming = "Thinking…"
                    state.toolRunning = false
                case "streaming_text":
                    state.streaming = "Replying…"
                    state.toolRunning = false
                default:
                    break // tool_execution / permission_prompt via their events
                }
            case "tool_started":
                sawTurnActivity = true
                state.toolRunning = true
            case "tool_completed":
                sawTurnActivity = true
                state.toolRunning = false
            case "permission_requested":
                sawTurnActivity = true
                permissionPending = true
            case "permission_resolved":
                sawTurnActivity = true
                permissionPending = false
            case "first_token", "loop_started":
                sawTurnActivity = true
            default:
                // mcp_server_* / mcp_transport_* noise arrives outside turns
                // too — it must not count as evidence of a turn in progress.
                break
            }
        }

        // Every turn's last event is turn_ended, so a tail window with turn
        // activity but no boundary can only be the middle of a long turn.
        if state.phase == .unknown, sawTurnActivity { state.phase = .working }

        // Blocked on an approval — that's "waiting for you", not working.
        if permissionPending { state.phase = .waiting }

        return state
    }

    /// Reduce a raw tail of events.jsonl (as fetched over SSH). The first
    /// line may be a fragment — unparsable lines are skipped.
    static func eventState(fromTailText text: String) -> EventState {
        let events = text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
        return reduceEvents(events)
    }

    private static func parseEvents(path: String, into info: inout Info) {
        let state = reduceEvents(tailEntries(path: path, bytes: 128 * 1024))
        info.phase = state.phase
        if state.phase == .working {
            // A named in-flight tool call (from the chat tail) wins; otherwise
            // report the streaming state.
            if info.activity == nil || !state.toolRunning {
                info.activity = state.streaming ?? info.activity ?? "Thinking…"
            }
        } else {
            info.activity = nil
        }
    }

    // MARK: - Detail chat

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
            switch obj["type"] as? String {
            case "user":
                if let text = userText(obj) { append(user: true, text: text) }
            case "assistant":
                if let text = obj["content"] as? String { append(user: false, text: text) }
            default:
                break
            }
        }
        return Array(messages.suffix(limit))
    }

    // MARK: - Helpers

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
}
