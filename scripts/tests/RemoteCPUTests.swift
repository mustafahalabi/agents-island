// Tests for deriving a remote agent's *recent* CPU usage.
//
// The bug: remote status came straight from `ps pcpu`. On macOS that is a
// decaying estimate of recent usage, but on Linux it means cumulative CPU time
// divided by elapsed lifetime — an average over the whole life of the process.
// So a remote agent that worked hard for its first few minutes and has been
// idle for an hour stayed pinned above the threshold and showed "working"
// forever, while one that had been up all day and was busy right now averaged
// below it and showed "idle".
//
// Compiled against the real RemoteCPU.swift by scripts/run-tests.sh.
import Foundation

@main
struct RemoteCPUTests {
    static var failures = 0

    static func fail(_ message: String, _ line: Int = #line) {
        failures += 1
        print("FAIL:\(line)  \(message)")
    }

    static func expectTime(_ raw: String, _ want: Double?, _ line: Int = #line) {
        let got = RemoteCPU.parseCPUTime(raw)
        if got != want {
            failures += 1
            print("FAIL:\(line)  parseCPUTime(\"\(raw)\") = \(String(describing: got)), want \(String(describing: want))")
        }
    }

    static func main() {
        // --- ps -o time= differs by platform ----------------------------------
        // Linux: HH:MM:SS, or D-HH:MM:SS past a day.
        expectTime("00:00:42", 42)
        expectTime("00:01:23", 83)
        expectTime("01:00:00", 3600)
        expectTime("1-02:03:04", 93_784)   // 1d 2h 3m 4s
        // macOS: MM:SS.ss, or HH:MM:SS past an hour.
        expectTime("0:00.42", 0.42)
        expectTime("12:34.56", 754.56)
        expectTime("2:03:04", 7384)
        // Padding and junk.
        expectTime("  00:00:10  ", 10)
        expectTime("", nil)
        expectTime("garbage", nil)
        expectTime("1:2:3:4", nil)

        // --- the actual bug ----------------------------------------------------
        // An agent that burned 30 minutes of CPU early and has been idle since.
        // Its lifetime average stays high; its recent usage is zero.
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let idleNow = RemoteCPU.recentPercent(
            previous: .init(cpuSeconds: 1800, at: t0),
            current:  .init(cpuSeconds: 1800, at: t0.addingTimeInterval(10)))
        if idleNow != 0 { fail("an idle agent should compute 0% recent, got \(String(describing: idleNow))") }
        if RemoteCPU.isWorking(recent: idleNow, lifetimeFallback: 85) {
            fail("a long-idle agent with a high lifetime average must not show working")
        }

        // The mirror case: busy right now, but a low lifetime average after a
        // day of mostly sitting idle.
        let busyNow = RemoteCPU.recentPercent(
            previous: .init(cpuSeconds: 1000, at: t0),
            current:  .init(cpuSeconds: 1008, at: t0.addingTimeInterval(10)))
        if busyNow != 80 { fail("8 CPU-seconds over 10s should be 80%, got \(String(describing: busyNow))") }
        if !RemoteCPU.isWorking(recent: busyNow, lifetimeFallback: 0.4) {
            fail("a busy agent with a low lifetime average must show working")
        }

        // --- no usable baseline -------------------------------------------------
        if RemoteCPU.recentPercent(previous: nil, current: .init(cpuSeconds: 5, at: t0)) != nil {
            fail("first sighting has no baseline and must yield nil")
        }
        // Too short a gap to mean anything.
        if RemoteCPU.recentPercent(previous: .init(cpuSeconds: 1, at: t0),
                                   current: .init(cpuSeconds: 2, at: t0.addingTimeInterval(0.1))) != nil {
            fail("a sub-second gap should not produce a figure")
        }
        // A counter that went backwards means the pid was recycled.
        if RemoteCPU.recentPercent(previous: .init(cpuSeconds: 100, at: t0),
                                   current: .init(cpuSeconds: 3, at: t0.addingTimeInterval(10))) != nil {
            fail("a decreasing CPU counter should be rejected as pid reuse")
        }

        // --- fallback behaviour --------------------------------------------------
        // With no recent figure yet, pcpu decides — correct on a macOS remote,
        // and only used for a single scan before the delta takes over.
        if !RemoteCPU.isWorking(recent: nil, lifetimeFallback: 50) {
            fail("first sighting should fall back to pcpu")
        }
        if RemoteCPU.isWorking(recent: nil, lifetimeFallback: 0.2) {
            fail("first sighting with low pcpu should be idle")
        }
        // A recent figure always wins over the fallback.
        if RemoteCPU.isWorking(recent: 0.1, lifetimeFallback: 99) {
            fail("the recent figure must override the lifetime average")
        }

        // Threshold boundary: strictly greater than.
        if RemoteCPU.isWorking(recent: 3.0, lifetimeFallback: 0) { fail("3.0 is not above the threshold") }
        if !RemoteCPU.isWorking(recent: 3.1, lifetimeFallback: 0) { fail("3.1 is above the threshold") }

        if failures == 0 {
            print("✅ RemoteCPUTests: all passed (remote status uses recent, not lifetime, CPU)")
        } else {
            print("❌ RemoteCPUTests: \(failures) failure(s)"); exit(1)
        }
    }
}
