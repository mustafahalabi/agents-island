import SwiftUI

enum AgentKind: String, CaseIterable {
    case claude
    case codex
    case gemini
    case opencode
    case cursorAgent = "cursor-agent"
    case copilot
    // Major-lab CLI agents (verified command names).
    case qwen
    case kimi
    case deepseek
    case grok
    case mistral

    /// Everything the UI needs to render an agent, in one place so adding an
    /// agent is a single table row rather than edits across five switches.
    struct Meta {
        let displayName: String
        let rgb: (Double, Double, Double)
        let symbol: String            // SF Symbol fallback when no brand icon
        let iconFile: String?         // Resources/agents/<name>.png, nil = symbol
        let aliases: [String]         // extra executable basenames that map here
    }

    var meta: Meta { Self.table[self] ?? Meta(displayName: rawValue.capitalized, rgb: (0.5, 0.5, 0.55), symbol: "terminal.fill", iconFile: nil, aliases: []) }

    var displayName: String { meta.displayName }
    var color: Color { Color(red: meta.rgb.0, green: meta.rgb.1, blue: meta.rgb.2) }
    var symbol: String { meta.symbol }
    /// Bundled brand icon (Resources/agents/<name>.png), nil = SF symbol fallback.
    var iconFile: String? { meta.iconFile }

    private static let table: [AgentKind: Meta] = [
        .claude:      Meta(displayName: "Claude",   rgb: (0.85, 0.47, 0.34), symbol: "sparkle",         iconFile: "claude-color",  aliases: []),
        .codex:       Meta(displayName: "Codex",    rgb: (0.06, 0.64, 0.50), symbol: "curlybraces",     iconFile: "openai",        aliases: []),
        .gemini:      Meta(displayName: "Gemini",   rgb: (0.31, 0.53, 0.97), symbol: "diamond.fill",    iconFile: "gemini-color",  aliases: []),
        .opencode:    Meta(displayName: "OpenCode", rgb: (0.35, 0.78, 0.98), symbol: "terminal.fill",   iconFile: "opencode",      aliases: []),
        .cursorAgent: Meta(displayName: "Cursor",   rgb: (0.62, 0.62, 0.68), symbol: "cursorarrow",     iconFile: "cursor",        aliases: ["cursor"]),
        .copilot:     Meta(displayName: "Copilot",  rgb: (0.45, 0.49, 0.55), symbol: "eyeglasses",      iconFile: "githubcopilot", aliases: []),
        .qwen:        Meta(displayName: "Qwen",     rgb: (0.38, 0.36, 0.93), symbol: "diamond.fill",    iconFile: "qwen",     aliases: ["qwen-code"]),
        .kimi:        Meta(displayName: "Kimi",     rgb: (0.12, 0.12, 0.15), symbol: "moon.stars.fill", iconFile: "kimi",     aliases: ["kimi-code"]),
        .deepseek:    Meta(displayName: "DeepSeek", rgb: (0.30, 0.42, 1.00), symbol: "magnifyingglass", iconFile: "deepseek", aliases: ["deepcode"]),
        .grok:        Meta(displayName: "Grok",     rgb: (0.12, 0.12, 0.14), symbol: "x.circle.fill",   iconFile: "grok",     aliases: ["grok-cli"]),
        .mistral:     Meta(displayName: "Mistral",  rgb: (0.98, 0.32, 0.06), symbol: "wind",            iconFile: "mistral",  aliases: ["vibe", "mistral-vibe"]),
    ]

    /// Match a process executable basename to an agent kind — by rawValue first,
    /// then by any registered alias (so "cursor" maps to the cursor-agent kind).
    init?(matching basename: String) {
        let name = basename.lowercased()
        if let kind = AgentKind(rawValue: name) { self = kind; return }
        for kind in AgentKind.allCases where kind.meta.aliases.contains(name) {
            self = kind
            return
        }
        return nil
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

struct Subagent: Equatable {
    let description: String
    let type: String?   // e.g. "Explore", "general-purpose"
    let done: Bool
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
    var subagents: [Subagent] = []
    var plan: String?          // markdown from the last ExitPlanMode call
    var remoteHost: String?    // set for sessions discovered over SSH

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
