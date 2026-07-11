import Foundation

/// Reads Claude Code's live session registry (~/.claude/sessions/<pid>.json)
/// and session transcripts (~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl)
/// to enrich Claude agents with titles, prompts, activity, and real status.
enum ClaudeSessions {

    struct Meta {
        let pid: Int32
        let sessionId: String
        let cwd: String
        let name: String?
        let status: String?         // "busy" | "idle"
        let statusUpdatedAt: Double? // epoch ms
    }

    struct TranscriptInfo: Equatable {
        var title: String?
        var lastPrompt: String?
        var activity: String?
        var model: String?
        var todos: [Todo] = []
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    // MARK: - Session registry

    /// All live sessions keyed by pid. Files for dead pids may linger; the
    /// caller cross-checks against the process table.
    static func sessionsByPid() -> [Int32: Meta] {
        let dir = home + "/.claude/sessions"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [:] }

        var result: [Int32: Meta] = [:]
        for file in files where file.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: dir + "/" + file),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = (obj["pid"] as? NSNumber)?.int32Value,
                  let sessionId = obj["sessionId"] as? String,
                  let cwd = obj["cwd"] as? String
            else { continue }
            result[pid] = Meta(
                pid: pid,
                sessionId: sessionId,
                cwd: cwd,
                name: obj["name"] as? String,
                status: obj["status"] as? String,
                statusUpdatedAt: (obj["statusUpdatedAt"] as? NSNumber)?.doubleValue
            )
        }
        return result
    }

    static func transcriptPath(for meta: Meta) -> String {
        let encoded = String(meta.cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return home + "/.claude/projects/\(encoded)/\(meta.sessionId).jsonl"
    }

    // MARK: - Task store (~/.claude/tasks/<sessionId>/<n>.json)

    /// The current task system. Each task is one JSON file:
    /// { id, subject, status: pending|in_progress|completed, ... }
    static func tasks(sessionId: String) -> [Todo] {
        let dir = home + "/.claude/tasks/" + sessionId
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }

        var items: [(order: Int, todo: Todo)] = []
        for file in files where file.hasSuffix(".json") && !file.hasPrefix(".") {
            guard let data = FileManager.default.contents(atPath: dir + "/" + file),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let subject = obj["subject"] as? String
            else { continue }
            let raw = obj["status"] as? String ?? "pending"
            if raw == "deleted" || raw == "cancelled" { continue }
            let status = ["completed", "in_progress"].contains(raw) ? raw : "pending"
            let order = Int((file as NSString).deletingPathExtension) ?? 0
            items.append((order, Todo(content: subject, status: status)))
        }
        return items.sorted { $0.order < $1.order }.map(\.todo)
    }

    // MARK: - Transcript tail parsing

    private static var infoCache: [String: (mtime: Date, info: TranscriptInfo)] = [:]
    private static let cacheLock = NSLock()

    static func tailInfo(path: String) -> TranscriptInfo {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil

        cacheLock.lock()
        if let mtime, let cached = infoCache[path], cached.mtime == mtime {
            cacheLock.unlock()
            return cached.info
        }
        cacheLock.unlock()

        var info = TranscriptInfo()
        var pendingTools: [(id: String, description: String)] = []
        var resolvedToolIds = Set<String>()

        for obj in tailEntries(path: path, bytes: 192 * 1024) {
            switch obj["type"] as? String {
            case "ai-title":
                if let t = obj["aiTitle"] as? String, !t.isEmpty { info.title = t }
            case "last-prompt":
                if let p = obj["lastPrompt"] as? String, !p.isEmpty { info.lastPrompt = p }
            case "assistant":
                if let message = obj["message"] as? [String: Any],
                   let model = message["model"] as? String, !model.isEmpty {
                    info.model = model
                }
                for item in contentItems(obj) {
                    if item["type"] as? String == "tool_use",
                       let id = item["id"] as? String,
                       let name = item["name"] as? String {
                        let input = item["input"] as? [String: Any] ?? [:]
                        pendingTools.append((id, describeTool(name: name, input: input)))
                        if name == "TodoWrite", let raw = input["todos"] as? [[String: Any]] {
                            info.todos = raw.compactMap { todo in
                                guard let content = todo["content"] as? String else { return nil }
                                return Todo(content: content, status: todo["status"] as? String ?? "pending")
                            }
                        }
                    }
                }
            case "user":
                for item in contentItems(obj) where item["type"] as? String == "tool_result" {
                    if let id = item["tool_use_id"] as? String { resolvedToolIds.insert(id) }
                }
                // Fallback prompt if no last-prompt entry is in the tail window.
                if obj["isMeta"] as? Bool != true, info.lastPrompt == nil,
                   let text = userText(obj), !text.isEmpty {
                    info.lastPrompt = text
                }
            default:
                break
            }
        }

        info.activity = pendingTools.last(where: { !resolvedToolIds.contains($0.id) })?.description

        if let mtime {
            cacheLock.lock()
            infoCache[path] = (mtime, info)
            cacheLock.unlock()
        }
        return info
    }

    /// Recent plain-text conversation messages for the detail view, oldest first.
    static func recentMessages(path: String, limit: Int = 12) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        var index = 0
        for obj in tailEntries(path: path, bytes: 384 * 1024) {
            switch obj["type"] as? String {
            case "user":
                guard obj["isMeta"] as? Bool != true, let text = userText(obj), !text.isEmpty else { continue }
                messages.append(ChatMessage(id: index, isUser: true, text: text))
                index += 1
            case "assistant":
                let texts = contentItems(obj)
                    .filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !joined.isEmpty else { continue }
                // Consecutive assistant texts in one turn: merge into the last bubble.
                if let last = messages.last, !last.isUser {
                    messages[messages.count - 1] = ChatMessage(id: last.id, isUser: false, text: last.text + "\n\n" + joined)
                } else {
                    messages.append(ChatMessage(id: index, isUser: false, text: joined))
                    index += 1
                }
            default:
                break
            }
        }
        return Array(messages.suffix(limit))
    }

    // MARK: - Helpers

    /// Parse the last `bytes` of a jsonl file into JSON objects (partial first line dropped).
    private static func tailEntries(path: String, bytes: Int) -> [[String: Any]] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [] }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if offset > 0, !lines.isEmpty { lines.removeFirst() } // partial line

        return lines.compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    private static func contentItems(_ entry: [String: Any]) -> [[String: Any]] {
        let message = entry["message"] as? [String: Any]
        return message?["content"] as? [[String: Any]] ?? []
    }

    private static func userText(_ entry: [String: Any]) -> String? {
        guard let message = entry["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        let texts = contentItems(entry)
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func describeTool(name: String, input: [String: Any]) -> String {
        func fileBase() -> String {
            ((input["file_path"] as? String ?? input["path"] as? String ?? "") as NSString).lastPathComponent
        }
        switch name {
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            let base = fileBase()
            return base.isEmpty ? "Writing files" : "Writing \(base)"
        case "Read":
            let base = fileBase()
            return base.isEmpty ? "Reading files" : "Reading \(base)"
        case "Bash":
            return input["description"] as? String ?? "Running a command"
        case "Grep", "Glob":
            return "Searching the codebase"
        case "Task", "Agent":
            return "Running a subagent"
        case "WebFetch", "WebSearch":
            return "Searching the web"
        case "TodoWrite", "TaskCreate", "TaskUpdate":
            return "Updating tasks"
        default:
            if name.hasPrefix("mcp__"), let tool = name.components(separatedBy: "__").last {
                return "Using \(tool.replacingOccurrences(of: "_", with: " "))"
            }
            return "Using \(name)"
        }
    }
}
