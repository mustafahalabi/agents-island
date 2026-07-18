// Tests for which prompt a session card displays.
//
// The bug: the user-message fallback was guarded by `info.lastPrompt == nil`,
// so the FIRST match in the tail window won and was never overwritten, while
// every other field is last-wins. Whenever a single turn produced more than
// 512KB of tool results — routine on a large repo — no `last-prompt` record
// remained in the window, and the card showed the OLDEST user message still
// visible rather than the most recent one.
//
// Drives the real tailInfo() against transcripts written to a temp directory.
// Compiled against the real ClaudeSessions.swift by scripts/run-tests.sh.
import Foundation

@main
struct LastPromptTests {
    static var failures = 0
    static let dir = NSTemporaryDirectory() + "ai-lastprompt-\(getpid())"

    static func fail(_ message: String, _ line: Int = #line) {
        failures += 1
        print("FAIL:\(line)  \(message)")
    }

    /// Write a transcript and read back what the card would show.
    static func prompt(from lines: [String], _ name: String) -> String? {
        let path = dir + "/\(name).jsonl"
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return ClaudeSessions.tailInfo(path: path).lastPrompt
    }

    static func userEntry(_ text: String) -> String {
        #"{"type":"user","message":{"role":"user","content":"\#(text)"}}"#
    }

    static func main() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // --- the regression: newest user message wins -------------------------
        let three = [userEntry("first question"),
                     userEntry("second question"),
                     userEntry("third question")]
        if prompt(from: three, "newest") != "third question" {
            fail("fallback showed \(prompt(from: three, "newest2") ?? "nil"), want the newest user message")
        }

        // --- last-prompt stays authoritative ----------------------------------
        // It is the session's own record; it must win wherever it sits in the
        // window, including when user entries follow it.
        let withRecord = [userEntry("older typed text"),
                          #"{"type":"last-prompt","lastPrompt":"the real prompt"}"#,
                          userEntry("trailing user entry")]
        if prompt(from: withRecord, "authoritative") != "the real prompt" {
            fail("last-prompt should win over user-message fallbacks")
        }

        // Newest last-prompt wins among several.
        let twoRecords = [#"{"type":"last-prompt","lastPrompt":"older"}"#,
                          #"{"type":"last-prompt","lastPrompt":"newer"}"#]
        if prompt(from: twoRecords, "tworecords") != "newer" {
            fail("the newest last-prompt should win")
        }

        // --- isMeta entries are not prompts -----------------------------------
        let withMeta = [userEntry("real prompt"),
                        #"{"type":"user","isMeta":true,"message":{"role":"user","content":"meta noise"}}"#]
        if prompt(from: withMeta, "meta") != "real prompt" {
            fail("an isMeta entry was treated as the prompt")
        }

        // --- degenerate input --------------------------------------------------
        if prompt(from: [#"{"type":"assistant","message":{"model":"opus"}}"#], "noprompt") != nil {
            fail("a transcript with no user text should yield no prompt")
        }
        if prompt(from: [], "empty") != nil {
            fail("an empty transcript should yield no prompt")
        }
        if ClaudeSessions.tailInfo(path: dir + "/does-not-exist.jsonl").lastPrompt != nil {
            fail("a missing transcript should yield no prompt")
        }

        if failures == 0 {
            print("✅ LastPromptTests: all passed (newest prompt wins, last-prompt still authoritative)")
        } else {
            print("❌ LastPromptTests: \(failures) failure(s)"); exit(1)
        }
    }
}
