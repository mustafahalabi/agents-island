// Tests for discovering Claude config directories beyond ~/.claude.
//
// The bug: sessions started with CLAUDE_CONFIG_DIR pointing at an account
// profile (~/.claude-profiles/<name>/, as account switchers do) wrote their
// registry and transcripts there, and the island — which only read ~/.claude —
// never showed them.
//
// Compiled against the real ClaudeSessions.swift by scripts/run-tests.sh.
import Foundation

@main
struct ConfigRootsTests {
    static var failures = 0

    static func fail(_ message: String, _ line: Int = #line) {
        failures += 1
        print("FAIL:\(line)  \(message)")
    }

    static func main() {
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "config-roots-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: home) }

        // No profiles directory at all: just the default.
        if ClaudeSessions.configRoots(home: home) != [home + "/.claude"] {
            fail("without ~/.claude-profiles only ~/.claude should be returned")
        }

        for dir in ["work/sessions", "personal/sessions", "_backups/sessions",
                    "_bin", ".hidden/sessions", "empty"] {
            try? fm.createDirectory(atPath: home + "/.claude-profiles/" + dir,
                                    withIntermediateDirectories: true)
        }
        fm.createFile(atPath: home + "/.claude-profiles/map.conf", contents: Data())

        let got = ClaudeSessions.configRoots(home: home)
        let want = [home + "/.claude",
                    home + "/.claude-profiles/personal",
                    home + "/.claude-profiles/work"]
        if got != want {
            fail("configRoots = \(got)\n        want \(want)")
        }

        if failures == 0 {
            print("✅ ConfigRootsTests: all passed (profiles discovered, bookkeeping skipped)")
        } else {
            print("❌ ConfigRootsTests: \(failures) failure(s)"); exit(1)
        }
    }
}
