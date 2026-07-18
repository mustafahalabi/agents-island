// Tests for mapping Codex processes to their rollout (transcript) files.
//
// The bug these cover: the pid → rollout cache was never pruned. Rollout files
// are never deleted, so `fileExists` never expired an entry, and macOS recycles
// pids — a new codex session landing on a retired pid inherited the previous
// session's rollout and showed its conversation. Separately, every cached
// rollout counted as "claimed" forever, so a fresh session in a directory that
// had an earlier one found its own rollout reserved by a dead pid and fell back
// to the older conversation.
//
// Compiled against the real RolloutAssignment.swift by scripts/run-tests.sh.
import Foundation

@main
struct RolloutAssignmentTests {
    static var failures = 0

    static func fail(_ message: String, _ line: Int = #line) {
        failures += 1
        print("FAIL:\(line)  \(message)")
    }

    static let roll1 = "/Users/me/.codex/sessions/2026/07/18/rollout-1.jsonl"
    static let roll2 = "/Users/me/.codex/sessions/2026/07/18/rollout-2.jsonl"
    static let roll3 = "/Users/me/.codex/sessions/2026/07/19/rollout-3.jsonl"

    static func main() {
        // --- pruning retires dead pids ---------------------------------------
        let cache: [Int32: String] = [100: roll1, 200: roll2, 300: roll3]

        let afterExit = RolloutAssignment.pruned(cache, livePids: [200, 300])
        if afterExit[100] != nil { fail("exited pid 100 kept its mapping") }
        if afterExit[200] != roll2 || afterExit[300] != roll3 {
            fail("pruning dropped a live pid's mapping")
        }

        if !RolloutAssignment.pruned(cache, livePids: []).isEmpty {
            fail("no live codex processes should empty the cache")
        }
        if RolloutAssignment.pruned([:], livePids: [1, 2]).count != 0 {
            fail("pruning an empty cache should stay empty")
        }
        if RolloutAssignment.pruned(cache, livePids: [100, 200, 300]).count != 3 {
            fail("pruning dropped mappings while every pid was still alive")
        }

        // --- the pid-reuse scenario ------------------------------------------
        // pid 100 held roll1 and exited. macOS recycles 100 for a brand-new
        // codex session. After a scan prunes, 100 must have no mapping at all,
        // so the caller performs a fresh lookup instead of inheriting roll1.
        let recycled = RolloutAssignment.pruned(cache, livePids: [200, 300])
        if recycled[100] != nil {
            fail("recycled pid would inherit the previous session's rollout")
        }

        // --- the starvation scenario ------------------------------------------
        // One directory has two rollouts. roll1 (the newest) was claimed by
        // pid 100, which has since exited; roll2 was never claimed.
        let candidates = [roll1, roll2]                 // newest first
        let deadPidCache: [Int32: String] = [100: roll1]

        // Unpruned, the dead pid still holds roll1, so the new session is
        // pushed onto the older conversation. This is the bug.
        let stale = Set(deadPidCache.values)
        if RolloutAssignment.select(candidates: candidates, assigned: stale) != roll2 {
            fail("precondition: an unpruned cache should starve the new session onto roll2")
        }

        // Pruned against an empty live set, roll1 is released and the new
        // session gets the rollout it should have had.
        let live = Set(RolloutAssignment.pruned(deadPidCache, livePids: []).values)
        if RolloutAssignment.select(candidates: candidates, assigned: live) != roll1 {
            fail("after pruning, the newest free rollout should be selected")
        }

        // A rollout held by a *live* pid stays reserved — pruning must not
        // hand one session's transcript to another.
        let stillLive = Set(RolloutAssignment.pruned(deadPidCache, livePids: [100]).values)
        if RolloutAssignment.select(candidates: candidates, assigned: stillLive) != roll2 {
            fail("a live pid's rollout must stay claimed")
        }

        // --- selection basics --------------------------------------------------
        if RolloutAssignment.select(candidates: [], assigned: []) != nil {
            fail("no candidates should yield nil")
        }
        if RolloutAssignment.select(candidates: [roll1, roll2], assigned: []) != roll1 {
            fail("with nothing claimed, the newest should win")
        }
        // Genuinely contended: both claimed by *live* processes. Falling back to
        // the newest is deliberate — showing the most recent conversation beats
        // showing none.
        if RolloutAssignment.select(candidates: [roll1, roll2],
                                    assigned: [roll1, roll2]) != roll1 {
            fail("all-claimed should fall back to the newest candidate")
        }

        if failures == 0 {
            print("✅ RolloutAssignmentTests: all passed (dead pids no longer hold rollouts)")
        } else {
            print("❌ RolloutAssignmentTests: \(failures) failure(s)"); exit(1)
        }
    }
}
