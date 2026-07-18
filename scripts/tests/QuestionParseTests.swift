// Regression test for parsing a pending AskUserQuestion out of a Claude
// transcript (the choice-buttons feature). Runs the real
// ClaudeSessions.tailInfo against a synthetic .jsonl, compiled by
// scripts/run-tests.sh alongside Agent.swift + ClaudeSessions.swift.
import Foundation

@main
struct QuestionParseTests {
    static func main() {
        // A transcript with an already-answered question (must be ignored) and
        // a later pending one (must be surfaced).
        let jsonl = """
        {"type":"assistant","timestamp":"2026-07-18T10:00:00.000Z","message":{"model":"claude-opus-4","content":[{"type":"text","text":"Working"}]}}
        {"type":"assistant","timestamp":"2026-07-18T10:00:01.000Z","message":{"content":[{"type":"tool_use","id":"tu_answered","name":"AskUserQuestion","input":{"questions":[{"question":"Old","header":"H","multiSelect":false,"options":[{"label":"A"},{"label":"B"}]}]}}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_answered"}]}}
        {"type":"assistant","timestamp":"2026-07-18T10:00:02.000Z","message":{"content":[{"type":"tool_use","id":"tu_pending","name":"AskUserQuestion","input":{"questions":[{"question":"Ship it?","header":"Choice","multiSelect":false,"options":[{"label":"Release now"},{"label":"Tweak first"},{"label":"Hold"}]}]}}]}}
        """
        let path = NSTemporaryDirectory() + "ai-qtest-\(ProcessInfo.processInfo.processIdentifier).jsonl"
        try? jsonl.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        var failures = 0
        func check(_ cond: Bool, _ msg: String) { if !cond { failures += 1; print("FAIL: \(msg)") } }

        let info = ClaudeSessions.tailInfo(path: path)
        check(info.question != nil, "expected a pending question, got nil")
        check(info.question?.prompt == "Ship it?", "prompt should be the pending question, not the answered one")
        check(info.question?.options == ["Release now", "Tweak first", "Hold"], "options mismatch: \(info.question?.options ?? [])")
        check(info.question?.multiSelect == false, "multiSelect should be false")

        if failures == 0 {
            print("✅ QuestionParseTests: pending AskUserQuestion parsed, answered one ignored")
            exit(0)
        } else {
            print("❌ QuestionParseTests: \(failures) failure(s)")
            exit(1)
        }
    }
}
