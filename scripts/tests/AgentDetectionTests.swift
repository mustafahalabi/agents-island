// Regression tests for AgentKind detection (the highest-churn logic: 22 agents,
// aliases, and false-positive avoidance). Compiled against the real Agent.swift
// by scripts/run-tests.sh — no test target needed (the app is an executable
// SwiftPM target, which XCTest can't @testable-import without a library split).
import Foundation

@main
struct AgentDetectionTests {
    static var failures = 0

    static func expect(_ command: String, _ want: AgentKind?, _ line: Int = #line) {
        let got = AgentKind(matching: command)
        if got != want {
            failures += 1
            print("FAIL:\(line)  matching(\"\(command)\") = \(got.map { $0.rawValue } ?? "nil"), want \(want.map { $0.rawValue } ?? "nil")")
        }
    }

    static func main() {
        // Verified CLI command names + aliases resolve to the right kind.
        expect("claude", .claude)
        expect("codex", .codex)
        expect("gemini", .gemini)
        expect("cursor", .cursorAgent)        // alias
        expect("cursor-agent", .cursorAgent)
        expect("qwen", .qwen); expect("qwen-code", .qwen)
        expect("kimi", .kimi); expect("kimi-code", .kimi)
        expect("deepcode", .deepseek)          // real command name
        expect("grok", .grok); expect("grok-cli", .grok)
        expect("vibe", .mistral)               // Mistral's command is `vibe`
        expect("opencode", .opencode)
        expect("copilot", .copilot)

        // GUI-only tools and collisions must NOT be detected.
        expect("zed", nil)                     // GUI editor, no agent CLI
        expect("windsurf", nil)                // GUI editor
        expect("glm", nil)                     // no standalone CLI
        expect("hermes", nil)                  // collides with the RN Hermes VM

        // Pruned agents (removed from the tracked set) must not be detected.
        for command in ["aider", "goose", "amp", "droid", "antigravity", "agy",
                        "qodercli", "codebuddy", "trae-cli", "kiro-cli", "gjc", "mimo"] {
            expect(command, nil)
        }

        // Non-agents.
        for command in ["node", "python", "python3", "bash", "sh", "go", "grep", "ssh", "vim"] {
            expect(command, nil)
        }

        // Case-insensitive.
        expect("Claude", .claude)
        expect("QWEN", .qwen)

        if failures == 0 {
            print("✅ AgentDetectionTests: all passed (\(AgentKind.allCases.count) kinds registered)")
            exit(0)
        } else {
            print("❌ AgentDetectionTests: \(failures) failure(s)")
            exit(1)
        }
    }
}
