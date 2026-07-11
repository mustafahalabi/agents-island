import SwiftUI

enum AgentKind: String, CaseIterable {
    case claude
    case codex
    case gemini
    case aider
    case goose
    case opencode
    case amp
    case cursorAgent = "cursor-agent"
    case copilot
    case droid

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .aider: return "Aider"
        case .goose: return "Goose"
        case .opencode: return "OpenCode"
        case .amp: return "Amp"
        case .cursorAgent: return "Cursor"
        case .copilot: return "Copilot"
        case .droid: return "Droid"
        }
    }

    var color: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color(red: 0.06, green: 0.64, blue: 0.50)
        case .gemini: return Color(red: 0.31, green: 0.53, blue: 0.97)
        case .aider: return Color(red: 0.18, green: 0.80, blue: 0.44)
        case .goose: return Color(red: 0.61, green: 0.35, blue: 0.71)
        case .opencode: return Color(red: 0.35, green: 0.78, blue: 0.98)
        case .amp: return Color(red: 0.96, green: 0.26, blue: 0.21)
        case .cursorAgent: return Color(red: 0.62, green: 0.62, blue: 0.68)
        case .copilot: return Color(red: 0.45, green: 0.49, blue: 0.55)
        case .droid: return Color(red: 0.93, green: 0.42, blue: 0.10)
        }
    }

    /// Bundled brand icon (Resources/agents/<name>.png), nil = SF symbol fallback.
    var iconFile: String? {
        switch self {
        case .claude: return "claude-color"
        case .codex: return "openai"
        case .gemini: return "gemini-color"
        case .copilot: return "githubcopilot"
        case .cursorAgent: return "cursor"
        case .opencode: return "opencode"
        case .goose: return "goose"
        case .amp: return "amp-color"
        case .aider, .droid: return nil
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "curlybraces"
        case .gemini: return "diamond.fill"
        case .aider: return "wand.and.rays"
        case .goose: return "bird.fill"
        case .opencode: return "terminal.fill"
        case .amp: return "bolt.fill"
        case .cursorAgent: return "cursorarrow"
        case .copilot: return "eyeglasses"
        case .droid: return "cpu.fill"
        }
    }

    /// Match a process executable basename to an agent kind.
    init?(matching basename: String) {
        self.init(rawValue: basename.lowercased())
    }
}

enum AgentStatus: Equatable {
    case working       // actively generating / running tools
    case waiting       // done, waiting for the user's reply
    case idle          // no recent activity

    var color: Color {
        switch self {
        case .working: return Color(red: 0.30, green: 0.85, blue: 0.40)
        case .waiting: return Color(red: 1.00, green: 0.72, blue: 0.25)
        case .idle: return Color(white: 0.55)
        }
    }

    var label: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Waiting for you"
        case .idle: return "Idle"
        }
    }
}

struct Todo: Equatable {
    let content: String
    let status: String // "pending" | "in_progress" | "completed"
}

struct AgentSession: Identifiable, Equatable {
    let id: Int32 // pid
    let kind: AgentKind
    var cpu: Double
    var elapsed: String
    var cwd: String?
    var status: AgentStatus
    var terminalApp: String?
    var tty: String?
    var bypassPermissions: Bool
    var todos: [Todo] = []

    // Rich fields (Claude Code sessions, via ~/.claude)
    var title: String?
    var lastPrompt: String?
    var activity: String?      // e.g. "Writing middleware.ts"
    var transcriptPath: String?
    var model: String?         // raw model id from the transcript, e.g. "claude-opus-4-8"
    var gitBranch: String?     // current branch of the session's cwd

    /// "claude-opus-4-8" → "Opus 4.8", "claude-sonnet-5" → "Sonnet 5",
    /// "gpt-5-codex" → "GPT 5 Codex", "o4-mini" → "O4 Mini".
    var modelDisplay: String? {
        guard var id = model?.lowercased() else { return nil }
        // The agent chip already says Claude/Gemini — don't repeat it.
        for prefix in ["claude-", "gemini-"] where id.hasPrefix(prefix) {
            id.removeFirst(prefix.count)
        }
        // Strip a date suffix like -20251001.
        let parts = id.split(separator: "-").filter { !($0.count == 8 && Int($0) != nil) }
        guard parts.contains(where: { Int($0) == nil }) else { return model }
        var words: [String] = []
        for part in parts {
            if Int(part) != nil, let last = words.last, Int(last) != nil {
                words[words.count - 1] = last + "." + part // version run: 4-8 → 4.8
            } else if Int(part) != nil {
                words.append(String(part))
            } else if part == "gpt" {
                words.append("GPT")
            } else {
                words.append(part.prefix(1).uppercased() + part.dropFirst())
            }
        }
        return words.joined(separator: " ")
    }

    var displayTitle: String {
        if let title, title.count > 1 { return title }
        return cwdDisplay
    }

    var cwdDisplay: String {
        guard let cwd, !cwd.isEmpty else { return kind.displayName + " session" }
        let base = (cwd as NSString).lastPathComponent
        return base.count > 1 ? base : kind.displayName + " session"
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: Int
    let isUser: Bool
    let text: String
}
