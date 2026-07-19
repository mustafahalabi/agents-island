import Foundation
import CryptoKit

/// Reads Gemini CLI's per-project data (~/.gemini/tmp/<sha256-of-cwd>/) to
/// enrich Gemini agents: last prompt from logs.json, conversation from saved
/// chat/checkpoint files, model from settings. Gemini writes no task events,
/// so working/waiting stays CPU-based (with a short post-prompt grace period).
enum GeminiSessions {

    struct Info: Equatable {
        var lastPrompt: String?
        var promptAge: TimeInterval? // seconds since the last user prompt
        var chatPath: String?        // newest saved conversation, if any
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    private static var infoCache: [String: (mtime: Date, info: Info)] = [:]
    private static var settingsModel: (loaded: Bool, mtime: Date?, model: String?) = (false, nil, nil)
    private static let lock = NSLock()

    /// Gemini keys project data by the SHA-256 hex of the project root path.
    static func projectDir(cwd: String) -> String? {
        let hash = SHA256.hash(data: Data(cwd.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let dir = home + "/.gemini/tmp/" + hash
        return FileManager.default.fileExists(atPath: dir) ? dir : nil
    }

    static func info(cwd: String) -> Info {
        guard let dir = projectDir(cwd: cwd) else { return Info() }
        let logsPath = dir + "/logs.json"
        let mtime = (try? FileManager.default.attributesOfItem(atPath: logsPath)[.modificationDate] as? Date) ?? nil

        lock.lock()
        if let mtime, let cached = infoCache[dir], cached.mtime == mtime {
            lock.unlock()
            var info = cached.info
            info.promptAge = info.promptAge.map { _ in Date().timeIntervalSince(mtime) }
            // chatPath is deliberately recomputed rather than served from the
            // cache. The whole Info was keyed on logs.json's mtime, but Gemini
            // writes logs.json when the user submits a prompt while chat and
            // checkpoint files are written as the conversation is saved — so a
            // newly saved conversation was invisible until the user typed
            // again, and the detail view kept rendering the previous one. This
            // is a directory listing, not a parse.
            info.chatPath = newestChat(in: dir)
            return info
        }
        lock.unlock()

        var info = Info()
        info.chatPath = newestChat(in: dir)

        // logs.json: [{sessionId, messageId, timestamp, type: "user", message}]
        if let data = FileManager.default.contents(atPath: logsPath),
           let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            if let last = entries.last(where: { $0["type"] as? String == "user" }),
               let message = last["message"] as? String, !message.isEmpty {
                info.lastPrompt = message
            }
        }
        if info.lastPrompt != nil, let mtime {
            info.promptAge = Date().timeIntervalSince(mtime)
        }

        if let mtime {
            lock.lock()
            infoCache[dir] = (mtime, info)
            lock.unlock()
        }
        return info
    }

    /// Newest saved conversation: checkpoint-*.json in the project dir, or
    /// anything under chats/ (session persistence in newer CLI versions).
    private static func newestChat(in dir: String) -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        for file in (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        where file.hasPrefix("checkpoint") && file.hasSuffix(".json") {
            candidates.append(dir + "/" + file)
        }
        for file in (try? fm.contentsOfDirectory(atPath: dir + "/chats")) ?? []
        where file.hasSuffix(".json") {
            candidates.append(dir + "/chats/" + file)
        }
        func mtime(_ path: String) -> Date {
            ((try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil) ?? .distantPast
        }
        return candidates.max { mtime($0) < mtime($1) }
    }

    /// Saved conversation for the detail view, oldest first. Handles the
    /// Gemini Content shape ({role, parts:[{text}]}) at the root, or nested
    /// under "history"/"messages", plus {type, text/content} variants.
    static func recentMessages(path: String, limit: Int = 12) -> [ChatMessage] {
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data)
        else { return [] }

        var items: [[String: Any]] = []
        if let array = root as? [[String: Any]] {
            items = array
        } else if let obj = root as? [String: Any] {
            items = (obj["history"] as? [[String: Any]])
                ?? (obj["messages"] as? [[String: Any]])
                ?? []
        }

        var messages: [ChatMessage] = []
        var index = 0
        for item in items {
            let role = (item["role"] as? String) ?? (item["type"] as? String) ?? ""
            let isUser = role == "user"
            guard isUser || ["model", "assistant", "gemini"].contains(role) else { continue }

            var text = ""
            if let parts = item["parts"] as? [[String: Any]] {
                text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else if let content = item["content"] as? String {
                text = content
            } else if let plain = item["text"] as? String {
                text = plain
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue } // skip pure function-call turns

            if !isUser, let last = messages.last, !last.isUser {
                messages[messages.count - 1] = ChatMessage(id: last.id, isUser: false,
                                                           text: last.text + "\n\n" + text)
            } else {
                messages.append(ChatMessage(id: index, isUser: isUser, text: text))
                index += 1
            }
        }
        return Array(messages.suffix(limit))
    }

    /// Default model from ~/.gemini/settings.json ("model" string or
    /// {"model": {"name": …}}), used when the process args carry no -m flag.
    static func defaultModel() -> String? {
        let path = home + "/.gemini/settings.json"
        // Re-read when the file changes. This used to load once and stick for
        // the life of the process, so editing settings.json — or creating it
        // after the app had already looked — showed a stale or absent model
        // until the app was relaunched. A nil mtime (no file yet) is itself a
        // cache key, so the file appearing later is picked up.
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil

        lock.lock()
        defer { lock.unlock() }
        if settingsModel.loaded, settingsModel.mtime == mtime { return settingsModel.model }

        var model: String?
        if let data = FileManager.default.contents(atPath: path),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let name = obj["model"] as? String {
                model = name
            } else if let modelObj = obj["model"] as? [String: Any] {
                model = modelObj["name"] as? String
            }
        }
        settingsModel = (true, mtime, model)
        return model
    }
}
