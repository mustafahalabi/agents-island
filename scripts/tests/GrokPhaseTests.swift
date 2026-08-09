// Tests for whether a Grok card reports working/waiting and what it shows.
//
// The bug: Grok had no session parser at all, so its status came from the CPU
// heuristic. Grok's turn shape — server-side "Thought for 1.8s" at ~0% local
// CPU, then a tool-call CPU spike — flapped working ↔ idle on every thinking
// step, posting a completion notification and sound each time.
//
// Drives the real GrokSessions.info() against session dirs written to a temp
// directory. Compiled against the real GrokSessions.swift by run-tests.sh.
import Foundation

@main
struct GrokPhaseTests {
    static var failures = 0
    static let root = NSTemporaryDirectory() + "ai-grokphase-\(getpid())"
    static var seq = 0

    static func fail(_ message: String, _ line: Int = #line) {
        failures += 1
        print("FAIL:\(line)  \(message)")
    }

    /// Build a session dir with the given jsonl lines and run the real parser.
    static func info(events: [String], chat: [String] = [], summary: String? = nil) -> GrokSessions.Info {
        seq += 1
        let dir = root + "/session-\(seq)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? (events.joined(separator: "\n") + "\n")
            .write(toFile: dir + "/events.jsonl", atomically: true, encoding: .utf8)
        if !chat.isEmpty {
            try? (chat.joined(separator: "\n") + "\n")
                .write(toFile: dir + "/chat_history.jsonl", atomically: true, encoding: .utf8)
        }
        if let summary {
            try? summary.write(toFile: dir + "/summary.json", atomically: true, encoding: .utf8)
        }
        return GrokSessions.info(dir: dir)
    }

    static let turnStarted = #"{"ts":"t","type":"turn_started"}"#
    static let turnEnded   = #"{"ts":"t","type":"turn_ended"}"#
    static let reasoning   = #"{"ts":"t","type":"phase_changed","phase":"streaming_reasoning"}"#

    static func main() {
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        // --- the core: turn events give real status -----------------------------
        // Mid-turn "thinking" (near-zero CPU) must still be working — this is
        // exactly the state that used to flap to idle and fire a notification.
        let thinking = info(events: [turnStarted, reasoning])
        if thinking.phase != .working { fail("a started turn should be working, got \(thinking.phase)") }
        if thinking.activity != "Thinking…" { fail("reasoning should show Thinking…, got \(thinking.activity ?? "nil")") }

        let done = info(events: [turnStarted, reasoning, turnEnded])
        if done.phase != .waiting { fail("an ended turn should be waiting, got \(done.phase)") }
        if done.activity != nil { fail("an ended turn should have no activity, got \(done.activity!)") }

        // --- a long turn whose start scrolled out of the tail window ------------
        // Every turn's last event is turn_ended, so events without a turn
        // boundary can only be the middle of a long turn — still working.
        let midTurn = info(events: [reasoning,
                                    #"{"ts":"t","type":"tool_started","tool_name":"run_terminal_command"}"#])
        if midTurn.phase != .working { fail("mid-turn events without boundaries should be working") }

        // --- an empty/unparsable stream stays unknown ---------------------------
        let empty = info(events: [])
        if empty.phase != .unknown { fail("no events should be unknown, got \(empty.phase)") }

        // --- a pending permission is waiting-for-you ----------------------------
        let blocked = info(events: [turnStarted,
                                    #"{"ts":"t","type":"permission_requested","tool_name":"write"}"#])
        if blocked.phase != .waiting { fail("a pending permission should be waiting, got \(blocked.phase)") }
        let approved = info(events: [turnStarted,
                                     #"{"ts":"t","type":"permission_requested","tool_name":"write"}"#,
                                     #"{"ts":"t","type":"permission_resolved","tool_name":"write","decision":"allow"}"#])
        if approved.phase != .working { fail("a resolved permission should be working again") }

        // --- activity names the in-flight tool call from the chat tail ----------
        let call = #"{"type":"assistant","content":"","tool_calls":[{"id":"c1","name":"run_terminal_command","arguments":"{\"command\":\"npm test\"}"}]}"#
        let result = #"{"type":"tool_result","tool_call_id":"c1","content":"ok"}"#
        let running = info(
            events: [turnStarted,
                     #"{"ts":"t","type":"phase_changed","phase":"tool_execution"}"#,
                     #"{"ts":"t","type":"tool_started","tool_name":"run_terminal_command"}"#],
            chat: [call])
        if running.activity != "Running npm test" {
            fail("an unresolved tool call should name the command, got \(running.activity ?? "nil")")
        }
        // A resolved call must not linger as activity once the model thinks again.
        let resolved = info(events: [turnStarted, reasoning], chat: [call, result])
        if resolved.activity != "Thinking…" {
            fail("a resolved tool call should not linger, got \(resolved.activity ?? "nil")")
        }

        // --- prompt extraction: <user_query> wrapper, injected context skipped ---
        let wrapped = #"{"type":"user","content":[{"type":"text","text":"<user_query>\nfix the login bug\n</user_query>\nExtra context"}]}"#
        let injected = #"{"type":"user","content":[{"type":"text","text":"<system_reminder>not typed by a human</system_reminder>"}]}"#
        let prompted = info(events: [turnStarted], chat: [wrapped, injected])
        if prompted.lastPrompt != "fix the login bug" {
            fail("lastPrompt should unwrap <user_query>, got \(prompted.lastPrompt ?? "nil")")
        }

        // --- todos come from the last todo_write --------------------------------
        let todoCall = #"{"type":"assistant","content":"","tool_calls":[{"id":"t1","name":"todo_write","arguments":"{\"todos\":[{\"id\":\"a\",\"content\":\"step one\",\"status\":\"in_progress\"},{\"id\":\"b\",\"content\":\"step two\",\"status\":\"pending\"}]}"}]}"#
        let todos = info(events: [turnStarted], chat: [todoCall, #"{"type":"tool_result","tool_call_id":"t1","content":"ok"}"#])
        if todos.todos.map(\.content) != ["step one", "step two"] {
            fail("todos should parse from todo_write, got \(todos.todos)")
        }

        // --- MCP noise is not turn activity -------------------------------------
        // mcp_transport_decode_error spam arrives while the session sits idle.
        // If it pushed turn_ended out of the tail window, "saw events → working"
        // would wrongly revive the session; noise alone must stay unknown.
        let noise = #"{"ts":"t","type":"mcp_transport_decode_error","server_name":"x","error":"y"}"#
        let noisy = info(events: [noise, noise, noise])
        if noisy.phase != .unknown { fail("mcp noise alone should be unknown, got \(noisy.phase)") }
        let noisyDone = info(events: [turnStarted, turnEnded, noise, noise])
        if noisyDone.phase != .waiting { fail("mcp noise after turn_ended should stay waiting") }

        // --- the SSH-tail reducer used by RemoteMonitor -------------------------
        // First line is a byte-offset fragment; the rest decide the phase.
        let remoteTail = "…fragment}\n" + turnStarted + "\n" + reasoning + "\n"
        let remoteState = GrokSessions.eventState(fromTailText: remoteTail)
        if remoteState.phase != .working { fail("remote tail mid-turn should be working") }
        let remoteDone = GrokSessions.eventState(fromTailText: turnStarted + "\n" + turnEnded + "\n")
        if remoteDone.phase != .waiting { fail("remote tail after turn_ended should be waiting") }

        // --- title + model from summary.json ------------------------------------
        let titled = info(events: [turnStarted, turnEnded],
                          summary: #"{"generated_title":"fix shell boot latency","current_model_id":"grok-4.5"}"#)
        if titled.title != "fix shell boot latency" { fail("title should come from summary.json") }
        if titled.model != "grok-4.5" { fail("model should come from summary.json") }

        if failures == 0 {
            print("✅ GrokPhaseTests: all passed (turn events drive status, no CPU flapping)")
        } else {
            print("❌ GrokPhaseTests: \(failures) failure(s)"); exit(1)
        }
    }
}
