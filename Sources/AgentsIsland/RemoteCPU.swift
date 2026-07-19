import Foundation

/// Turning a remote process's cumulative CPU time into a *recent* usage figure.
///
/// The local scan reads macOS `ps pcpu`, which is a decaying estimate of recent
/// usage. On Linux `ps pcpu` means something quite different: cumulative CPU
/// time divided by elapsed time since the process started — an average over the
/// process's entire lifetime.
///
/// Judging remote status by that average is unreliable in both directions. An
/// agent that worked hard for its first few minutes and has been idle for an
/// hour stays above the threshold and shows "working" indefinitely; an agent
/// that has been up all day and is busy right now averages below it and shows
/// "idle".
///
/// Sampling `ps time=` (cumulative CPU seconds) on consecutive scans and
/// dividing the difference by the wall-clock gap gives actual recent usage,
/// which is what `pcpu` already means on macOS.
enum RemoteCPU {

    /// One observation of a process's cumulative CPU time.
    struct Sample: Equatable {
        let cpuSeconds: Double
        let at: Date
    }

    /// Parse `ps -o time=`, which differs by platform:
    ///
    ///   Linux   `HH:MM:SS`, or `D-HH:MM:SS` past a day
    ///   macOS   `MM:SS.ss`, or `HH:MM:SS` past an hour
    ///
    /// Both are handled by reading the colon-separated fields from the right.
    static func parseCPUTime(_ raw: String) -> Double? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        var days = 0.0
        if let dash = text.firstIndex(of: "-") {
            guard let d = Double(text[text.startIndex..<dash]) else { return nil }
            days = d
            text = String(text[text.index(after: dash)...])
        }

        let fields = text.split(separator: ":")
        guard !fields.isEmpty, fields.count <= 3 else { return nil }

        var seconds = 0.0
        for field in fields {
            guard let value = Double(field) else { return nil }
            seconds = seconds * 60 + value
        }
        return days * 86_400 + seconds
    }

    /// Recent CPU percentage between two samples, or nil when there is no
    /// usable baseline (first sighting, clock skew, a counter that went
    /// backwards because the pid was recycled).
    static func recentPercent(previous: Sample?, current: Sample) -> Double? {
        guard let previous else { return nil }
        let wall = current.at.timeIntervalSince(previous.at)
        guard wall > 0.5 else { return nil }          // too short to be meaningful
        let cpu = current.cpuSeconds - previous.cpuSeconds
        guard cpu >= 0 else { return nil }            // pid reuse or counter reset
        return (cpu / wall) * 100
    }

    /// Decide status from the best figure available.
    ///
    /// `recent` is preferred; `lifetimeFallback` (`ps pcpu`) is only used on the
    /// first sighting, where it is correct on a macOS remote and merely a guess
    /// on Linux. One scan later the delta takes over.
    static func isWorking(recent: Double?, lifetimeFallback: Double, threshold: Double = 3.0) -> Bool {
        (recent ?? lifetimeFallback) > threshold
    }
}
