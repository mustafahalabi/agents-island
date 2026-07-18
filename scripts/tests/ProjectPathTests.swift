// Tests for encoding a project path the way Claude Code does.
//
// The bug: the encoder tested `isLetter || isNumber`, which is Unicode-wide, so
// `é`, CJK and even `²` passed and were kept verbatim. Claude Code applies
// /[^a-zA-Z0-9]/g per UTF-16 code unit. Any project path with a non-ASCII
// character resolved to a directory that does not exist, and the card showed no
// title, prompt, activity, model or todos — permanently, with no error.
//
// The expectation below is not inferred. A real `claude` session was run in
// /private/tmp/ai_probe_josé.test-dir and the CLI created
// -private-tmp-ai-probe-jos--test-dir.
//
// Compiled against the real ClaudeSessions.swift by scripts/run-tests.sh.
import Foundation

@main
struct ProjectPathTests {
    static var failures = 0

    static func expect(_ cwd: String, _ want: String, _ line: Int = #line) {
        let got = ClaudeSessions.projectDirName(for: cwd)
        if got != want {
            failures += 1
            print("FAIL:\(line)  \(cwd)\n        got  \(got)\n        want \(want)")
        }
    }

    static func main() {
        // --- ground truth, captured from the real CLI -------------------------
        expect("/private/tmp/ai_probe_josé.test-dir", "-private-tmp-ai-probe-jos--test-dir")

        // --- ordinary ASCII paths, matching real on-disk directory names ------
        expect("/Users/mustafa/Documents/projects/agents-island",
               "-Users-mustafa-Documents-projects-agents-island")
        expect("/private/tmp/eos-worker-cmr3csn5800038f4n8hwnblt8",
               "-private-tmp-eos-worker-cmr3csn5800038f4n8hwnblt8")
        // Case is preserved — confirmed against -Users-mustafa-Documents-projects.
        expect("/Users/Me/MyProject", "-Users-Me-MyProject")

        // --- every non-alphanumeric collapses to a single dash ----------------
        expect("/a_b", "-a-b")            // underscore is NOT preserved
        expect("/a.b", "-a-b")
        expect("/a b", "-a-b")
        expect("/a-b", "-a-b")            // already a dash, unchanged
        expect("/a@b#c", "-a-b-c")
        expect("", "")

        // --- non-ASCII: the actual bug ----------------------------------------
        // Each of these was previously kept verbatim, producing a path that
        // never exists on disk.
        expect("/Users/josé/proj", "-Users-jos--proj")
        expect("/Users/müller/code", "-Users-m-ller-code")
        expect("/projects/日本語", "-projects----")     // 3 CJK chars → 3 dashes
        expect("/a²b", "-a-b")                          // isNumber is true for ²
        expect("/naïve/café", "-na-ve-caf-")

        // --- decomposed vs precomposed ----------------------------------------
        // JavaScript's regex runs per UTF-16 code unit. A decomposed "é"
        // (e + U+0301) is two code units there: the `e` survives and the
        // combining mark becomes a dash. Treating it as one Swift Character
        // would emit a single dash and diverge.
        let precomposed = "/caf\u{00E9}"          // é as one scalar
        let decomposed  = "/cafe\u{0301}"         // e + combining acute
        expect(precomposed, "-caf-")
        expect(decomposed, "-cafe-")

        // --- astral plane ------------------------------------------------------
        // An emoji is a surrogate pair — two code units, so two dashes.
        expect("/x🎉y", "-x--y")

        if failures == 0 {
            print("✅ ProjectPathTests: all passed (encoding matches the real CLI)")
        } else {
            print("❌ ProjectPathTests: \(failures) failure(s)"); exit(1)
        }
    }
}
