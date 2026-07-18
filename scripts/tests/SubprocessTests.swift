// Tests for the subprocess timeout that keeps a wedged SSH host from freezing
// all remote scanning.
//
// The bug this covers: `readDataToEndOfFile()` returns only when the child's
// stdout closes, i.e. when it exits. ssh's ConnectTimeout bounds only the TCP
// connect, so a host that connects and then stalls in key exchange or auth left
// ssh running forever — blocking the serial scan queue, freezing every other
// host's status and every later scan until the app was relaunched.
//
// Uses /bin/sleep as a stand-in for a hung ssh: same observable behaviour, no
// network needed.
//
// Compiled against the real Subprocess.swift by scripts/run-tests.sh.
import Foundation

@main
struct SubprocessTests {
    static var failures = 0

    static func fail(_ message: String, _ line: Int = #line) {
        failures += 1
        print("FAIL:\(line)  \(message)")
    }

    static func main() {
        // --- a hung child must not block past the timeout --------------------
        var start = Date()
        var out = Subprocess.run("/bin/sleep", ["30"], timeout: 2)
        var elapsed = Date().timeIntervalSince(start)

        if out != nil { fail("a timed-out process should yield nil, got \(out!.count) bytes") }
        if elapsed > 6 {
            fail(String(format: "timeout did not fire: blocked %.1fs on a 2s budget", elapsed))
        }
        if elapsed < 1.5 {
            fail(String(format: "returned too early (%.1fs) — did it run at all?", elapsed))
        }

        // --- the child must actually be gone, not orphaned -------------------
        // A leaked `sleep` would mean the watchdog released our read without
        // killing the process, which is how ssh processes accumulated.
        let strays = Subprocess.run("/bin/ps", ["-Ao", "command"], timeout: 10) ?? ""
        if strays.contains("/bin/sleep 30") {
            fail("timed-out child was left running")
        }

        // --- normal commands still work unchanged ----------------------------
        out = Subprocess.run("/bin/echo", ["hello"], timeout: 10)
        if out?.trimmingCharacters(in: .whitespacesAndNewlines) != "hello" {
            fail("echo returned \(out ?? "nil")")
        }

        // A fast command must not wait for its timeout budget.
        start = Date()
        _ = Subprocess.run("/bin/echo", ["quick"], timeout: 30)
        elapsed = Date().timeIntervalSince(start)
        if elapsed > 5 { fail(String(format: "fast command took %.1fs — watchdog is blocking", elapsed)) }

        // --- failures are reported, not hung on -----------------------------
        if Subprocess.run("/nonexistent/binary", [], timeout: 5) != nil {
            fail("unlaunchable binary should yield nil")
        }

        // Non-zero exit still returns output: the remote scanner deliberately
        // does not gate on exit status (a good scan can exit non-zero), so this
        // behaviour has to be preserved.
        let mixed = Subprocess.run("/bin/sh", ["-c", "echo out; exit 3"], timeout: 10)
        if mixed?.trimmingCharacters(in: .whitespacesAndNewlines) != "out" {
            fail("non-zero exit should still return stdout, got \(mixed ?? "nil")")
        }

        // Output larger than a pipe buffer must not deadlock.
        let big = Subprocess.run("/bin/sh", ["-c", "yes x | head -c 200000"], timeout: 20)
        if (big?.count ?? 0) < 199_000 {
            fail("large output truncated or deadlocked: got \(big?.count ?? 0) bytes")
        }

        if failures == 0 {
            print("✅ SubprocessTests: all passed (a hung child can no longer block a scan)")
        } else {
            print("❌ SubprocessTests: \(failures) failure(s)"); exit(1)
        }
    }
}
