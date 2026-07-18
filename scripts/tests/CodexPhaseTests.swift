// Tests for whether a Codex card reports "working" and what it shows running.
//
// The bug: only "function_call_output" resolved a pending call. Codex writes
// shell results as "local_shell_call_output", which fell through `default:
// break`, so every completed shell call stayed pending forever. Once the
// task_complete event scrolled out of the 256KB window — a long turn with large
// tool output — phase was .unknown, the unresolved call forced it to .working,
// and the card showed "Running <an old command>" while Codex sat idle.
//
// Drives the real tailInfo() against rollouts written to a temp directory.
// Compiled against the real CodexSessions.swift by scripts/run-tests.sh.
import Foundation

@main
struct CodexPhaseTests {
    static var failures = 0
    static let dir = NSTemporaryDirectory() + "ai-codexphase-\(getpid())"
    static var seq = 0

    static func fail(_ message: String, _ line: Int = #line) {
        failures += 1
        print("FAIL:\(line)  \(message)")
    }

    static func info(_ lines: [String]) -> CodexSessions.Info {
        seq += 1
        let path = dir + "/rollout-\(seq).jsonl"
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return CodexSessions.tailInfo(path: path)
    }

    // Nested "response_item" form.
    static func item(_ json: String) -> String {
        #"{"type":"response_item","payload":\#(json)}"#
    }
    static let shellCall = #"{"type":"local_shell_call","call_id":"c1","action":{"command":["npm","test"]}}"#
    static let shellOut  = #"{"type":"local_shell_call_output","call_id":"c1","output":"ok"}"#

    static func main() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // --- the regression ---------------------------------------------------
        // A shell call that has completed, with no task event left in the
        // window. It must NOT report working, and must not name a stale command.
        let done = info([item(shellCall), item(shellOut)])
        if done.phase == .working {
            fail("a completed shell call still reports working — activity: \(done.activity ?? "nil")")
        }
        if done.activity != nil {
            fail("a completed shell call still shows activity: \(done.activity!)")
        }

        // A genuinely unresolved call SHOULD still report working — that
        // inference is the point of the fallback and must survive the fix.
        let running = info([item(shellCall)])
        if running.phase != .working { fail("an unresolved shell call should report working") }
        if running.activity == nil { fail("an unresolved shell call should name a command") }

        // --- the same, in the older flat format --------------------------------
        let flatDone = info([shellCall, shellOut])
        if flatDone.phase == .working { fail("flat format: completed shell call still reports working") }
        let flatRunning = info([shellCall])
        if flatRunning.phase != .working { fail("flat format: unresolved call should report working") }

        // --- function calls keep working (the path that was already handled) ---
        let fnCall = #"{"type":"function_call","call_id":"f1","name":"read_file","arguments":"{}"}"#
        let fnOut  = #"{"type":"function_call_output","call_id":"f1","output":"..."}"#
        if info([item(fnCall), item(fnOut)]).phase == .working {
            fail("a completed function call still reports working")
        }
        if info([item(fnCall)]).phase != .working {
            fail("an unresolved function call should report working")
        }

        // --- call_id / id asymmetry --------------------------------------------
        // The call side falls back to "id" when "call_id" is absent, so the
        // output side must too, or the pair never matches.
        let callById = #"{"type":"local_shell_call","id":"x9","action":{"command":["ls"]}}"#
        let outById  = #"{"type":"local_shell_call_output","id":"x9","output":"ok"}"#
        if info([item(callById), item(outById)]).phase == .working {
            fail("a call/output pair keyed by id never resolved")
        }

        // --- explicit task events still win ------------------------------------
        let completed = info([item(shellCall),
                              #"{"type":"event_msg","payload":{"type":"task_complete"}}"#])
        if completed.phase != .waiting {
            fail("task_complete should mark the session waiting, got \(completed.phase)")
        }
        let started = info([#"{"type":"event_msg","payload":{"type":"task_started"}}"#, item(shellCall)])
        if started.phase != .working { fail("task_started should mark the session working") }

        // --- unknown outputs resolve too ----------------------------------------
        // Matching on the *_call_output suffix means a future tool type does not
        // reintroduce this bug.
        let customCall = #"{"type":"custom_tool_call","call_id":"z1","name":"x","arguments":"{}"}"#
        let customOut  = #"{"type":"custom_tool_call_output","call_id":"z1","output":"ok"}"#
        _ = info([item(customCall), item(customOut)])   // must not crash

        if failures == 0 {
            print("✅ CodexPhaseTests: all passed (completed shell calls no longer look like work)")
        } else {
            print("❌ CodexPhaseTests: \(failures) failure(s)"); exit(1)
        }
    }
}
