// Tests for rewriting the user's ~/.claude/settings.json.
//
// The bug these cover: an unparseable settings file was read as an empty
// dictionary, merged into, and written back — silently destroying every setting
// the user had (permission rules, env, model, their own hooks). `load` now
// reports `.unreadable` distinctly from `.missing` so the caller can refuse.
//
// Compiled against the real HookSettings.swift by scripts/run-tests.sh.
import Foundation

@main
struct HookSettingsTests {
    static var failures = 0
    static let hook = "/Users/me/.claude/agents-island/notify-hook.sh"

    static func fail(_ message: String, _ line: Int = #line) {
        failures += 1
        print("FAIL:\(line)  \(message)")
    }

    static func hookCount(_ root: [String: Any], _ event: String) -> Int {
        let entries = (root["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        return entries.filter { entry in
            ((entry["hooks"] as? [[String: Any]]) ?? [])
                .contains { ($0["command"] as? String)?.contains("agents-island") == true }
        }.count
    }

    static func main() {
        // --- load: the distinction that prevents data loss -------------------
        if HookSettings.load(data: nil) != .missing { fail("nil data should be .missing") }
        if HookSettings.load(data: Data()) != .missing { fail("empty file should be .missing") }

        // Truncated / invalid JSON must NOT look like an empty settings file.
        for bad in [#"{"permissions": {"allow": ["Bash"]},"#, "not json at all", "[1,2,3]"] {
            if HookSettings.load(data: Data(bad.utf8)) != .unreadable {
                fail("malformed settings should be .unreadable, not empty: \(bad)")
            }
        }
        if case .parsed = HookSettings.load(data: Data(#"{"a":1}"#.utf8)) {} else {
            fail("valid JSON object should parse")
        }

        // --- merge preserves everything the user had -------------------------
        let user: [String: Any] = [
            "permissions": ["allow": ["Bash(git:*)"], "deny": ["Read(./.env)"]],
            "model": "opus",
            "env": ["FOO": "bar"],
        ]
        let merged = HookSettings.merged(into: user, hookPath: hook)
        for key in ["permissions", "model", "env"] where merged[key] == nil {
            fail("merge dropped the user's \(key)")
        }
        if hookCount(merged, "PermissionRequest") != 1 { fail("hook not registered") }
        if hookCount(merged, "PreToolUse") != 1 { fail("AskUserQuestion hook not registered") }

        // The AskUserQuestion entries must carry their matcher.
        let pre = (merged["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] ?? []
        if pre.first?["matcher"] as? String != "AskUserQuestion" { fail("missing matcher") }

        // --- idempotent: installing twice must not duplicate -----------------
        let twice = HookSettings.merged(into: merged, hookPath: hook)
        for event in ["PermissionRequest", "Notification", "PreToolUse", "PostToolUse"]
        where hookCount(twice, event) != 1 {
            fail("re-install duplicated the hook on \(event)")
        }

        // --- merge must not disturb the user's own hooks ---------------------
        let withUserHook: [String: Any] = [
            "hooks": ["PermissionRequest": [["hooks": [["type": "command",
                                                        "command": "/usr/local/bin/my-own-hook"]]]]]
        ]
        let coexist = HookSettings.merged(into: withUserHook, hookPath: hook)
        let entries = (coexist["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]] ?? []
        if entries.count != 2 { fail("merge clobbered the user's own hook (got \(entries.count) entries)") }

        // --- uninstall removes only ours -------------------------------------
        let cleaned = HookSettings.removed(from: coexist)
        let left = (cleaned["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]] ?? []
        if left.count != 1 { fail("uninstall should leave the user's hook, got \(left.count)") }
        if hookCount(cleaned, "PermissionRequest") != 0 { fail("uninstall left our hook behind") }

        // Uninstalling from a settings file that only ever had our hooks should
        // drop the now-empty "hooks" key rather than leaving debris.
        let onlyOurs = HookSettings.merged(into: [:], hookPath: hook)
        let empty = HookSettings.removed(from: onlyOurs)
        if empty["hooks"] != nil { fail("empty hooks dict should be removed entirely") }

        // Uninstall preserves unrelated settings.
        let full = HookSettings.merged(into: user, hookPath: hook)
        let stripped = HookSettings.removed(from: full)
        for key in ["permissions", "model", "env"] where stripped[key] == nil {
            fail("uninstall dropped the user's \(key)")
        }

        // --- round-trip through serialization --------------------------------
        guard let data = HookSettings.serialize(full),
              case .parsed(let reloaded) = HookSettings.load(data: data) else {
            fail("serialize/load round-trip failed")
            report(); return
        }
        if hookCount(reloaded, "Notification") != 1 { fail("hook lost in round-trip") }
        if (reloaded["model"] as? String) != "opus" { fail("user setting lost in round-trip") }

        report()
    }

    static func report() {
        if failures == 0 {
            print("✅ HookSettingsTests: all passed (unreadable settings are never overwritten)")
        } else {
            print("❌ HookSettingsTests: \(failures) failure(s)"); exit(1)
        }
    }
}
