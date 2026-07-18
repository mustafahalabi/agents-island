import Foundation

/// Estimates Claude usage-limit consumption from local transcripts, the way
/// ccusage-style tools do: every assistant entry carries `message.usage`;
/// we aggregate weighted tokens into hourly buckets, derive the active 5h
/// session block (Claude's rate-limit window: starts at the hour of the
/// first message after a ≥5h gap) and a rolling 7-day total, and compare
/// against per-plan budget estimates. All numbers are estimates — Anthropic
/// doesn't publish exact budgets.
final class UsageTracker: ObservableObject {
    static let shared = UsageTracker()

    struct Snapshot: Equatable {
        var blockTokens: Double = 0
        var blockResetAt: Date?
        var weekTokens: Double = 0

        func blockPercent(budget: Double) -> Int? {
            blockResetAt == nil ? nil : Int((blockTokens / budget * 100).rounded())
        }
        func weekPercent(budget: Double) -> Int {
            Int((weekTokens / budget * 100).rounded())
        }
    }

    /// (5h weighted-token budget, 7d budget) — rough community estimates.
    static func budgets(plan: String) -> (block: Double, week: Double) {
        switch plan {
        case "pro": return (8_000_000, 300_000_000)
        case "max20x": return (160_000_000, 6_000_000_000)
        default: return (40_000_000, 1_500_000_000) // max5x
        }
    }

    /// Codex reports its real server-side rate limits in each rollout's
    /// `token_count` events — no estimation needed, we surface them verbatim.
    struct CodexWindow: Equatable {
        var usedPercent: Double
        var resetsAt: Date?
        var windowMinutes: Int
        /// "5h" / "7d" style label derived from the window length.
        var label: String {
            if windowMinutes % 1440 == 0 { return "\(windowMinutes / 1440)d" }
            if windowMinutes % 60 == 0 { return "\(windowMinutes / 60)h" }
            return "\(windowMinutes)m"
        }
    }

    struct CodexSnapshot: Equatable {
        var primary: CodexWindow?
        var secondary: CodexWindow?
        var planType: String?
        var hasData: Bool { primary != nil || secondary != nil }
    }

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var codex = CodexSnapshot()

    /// Per-file incremental state: transcripts are append-only, so after the
    /// first full parse we only read new bytes.
    private struct FileState {
        var offset: UInt64
        var buckets: [Int: Double] // unix-hour → weighted tokens
    }

    private var files: [String: FileState] = [:]
    private var timer: Timer?
    private let queue = DispatchQueue(label: "agents-island.usage", qos: .utility)
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let iso = ISO8601DateFormatter()

    func start() {
        queue.async { self.recompute() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.queue.async { self?.recompute() }
        }
    }

    private func recompute() {
        guard UserDefaults.standard.bool(forKey: Pref.usageEnabled) else { return }
        let fm = FileManager.default
        let root = Self.home + "/.claude/projects"
        let horizon = Date().addingTimeInterval(-8 * 24 * 3600)

        var seen = Set<String>()
        if let enumerator = fm.enumerator(at: URL(fileURLWithPath: root),
                                          includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                          options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let mtime = values?.contentModificationDate, mtime > horizon else { continue }
                let size = UInt64(values?.fileSize ?? 0)
                let path = url.path
                seen.insert(path)

                var state = files[path] ?? FileState(offset: 0, buckets: [:])
                if size > state.offset {
                    ingest(path: path, state: &state)
                    files[path] = state
                } else if size < state.offset {
                    // Truncated/rewritten — reparse from scratch.
                    state = FileState(offset: 0, buckets: [:])
                    ingest(path: path, state: &state)
                    files[path] = state
                }
            }
        }
        files = files.filter { seen.contains($0.key) }

        publish()
        recomputeCodex()
    }

    // MARK: - Codex (exact server rate limits from ~/.codex rollouts)

    private func recomputeCodex() {
        guard let url = latestCodexRollout() else { return }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        // Rate-limit events are small and near the end; the last 128KB is plenty.
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 131_072 ? size - 131_072 : 0)
        guard let data = try? handle.readToEnd() else { return }
        // Lossy on purpose — the window can begin mid-character. A strict
        // decode failed the whole read, blanking the Codex usage meter. See
        // TailRead. The garbled first line simply fails to parse as JSON, as
        // a partial line always did.
        let text = TailRead.decode(data)

        var rate: [String: Any]?
        for line in text.split(separator: "\n") where line.contains("\"rate_limits\"") {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let rl = payload["rate_limits"] as? [String: Any] else { continue }
            rate = rl // keep the last (freshest) one
        }
        guard let rate else { return }

        func window(_ key: String) -> CodexWindow? {
            guard let w = rate[key] as? [String: Any],
                  let pct = (w["used_percent"] as? NSNumber)?.doubleValue,
                  let mins = (w["window_minutes"] as? NSNumber)?.intValue else { return nil }
            let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return CodexWindow(usedPercent: pct, resetsAt: reset, windowMinutes: mins)
        }

        let next = CodexSnapshot(
            primary: window("primary"),
            secondary: window("secondary"),
            planType: rate["plan_type"] as? String
        )
        DispatchQueue.main.async {
            if self.codex != next { self.codex = next }
        }
    }

    /// The most recently modified rollout under ~/.codex/sessions. We scan the
    /// latest month's day folders (not just today's) by mtime, so an empty
    /// current-day folder or a session that spans midnight still resolves.
    private func latestCodexRollout() -> URL? {
        let fm = FileManager.default
        func children(_ dir: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { !$0.hasPrefix(".") }.sorted()
        }
        let base = Self.home + "/.codex/sessions"
        guard let year = children(base).last.map({ base + "/" + $0 }),
              let month = children(year).last.map({ year + "/" + $0 }) else { return nil }

        var newest: (path: String, mtime: Date)?
        for day in children(month) {
            let dayDir = month + "/" + day
            for file in children(dayDir) where file.hasPrefix("rollout-") && file.hasSuffix(".jsonl") {
                let path = dayDir + "/" + file
                guard let m = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { continue }
                if newest == nil || m > newest!.mtime { newest = (path, m) }
            }
        }
        return newest.map { URL(fileURLWithPath: $0.path) }
    }

    /// Parse appended bytes into hourly weighted-token buckets.
    private func ingest(path: String, state: inout FileState) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: state.offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }

        // Only consume up to the last complete line; a partial tail line is
        // still being written and will be re-read next pass.
        var usable = data
        if data.last != UInt8(ascii: "\n") {
            if let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
                usable = data.prefix(through: lastNewline)
            } else {
                return
            }
        }
        state.offset += UInt64(usable.count)

        guard let text = String(data: usable, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            // Cheap pre-filter before JSON parsing 100MB+ of history.
            guard line.contains("\"usage\"") else { continue }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let stamp = obj["timestamp"] as? String,
                  let date = Self.isoFractional.date(from: stamp) ?? Self.iso.date(from: stamp)
            else { continue }

            func tokens(_ key: String) -> Double {
                (usage[key] as? NSNumber)?.doubleValue ?? 0
            }
            // Cache reads are drastically cheaper — weight them down so the
            // estimate tracks cost/limits rather than raw bytes.
            let weighted = tokens("input_tokens")
                + tokens("output_tokens")
                + tokens("cache_creation_input_tokens")
                + tokens("cache_read_input_tokens") * 0.1
            guard weighted > 0 else { continue }
            let hour = Int(date.timeIntervalSince1970 / 3600)
            state.buckets[hour, default: 0] += weighted
        }
    }

    private func publish() {
        let nowHour = Int(Date().timeIntervalSince1970 / 3600)
        let weekStart = nowHour - 7 * 24

        var merged: [Int: Double] = [:]
        for state in files.values {
            for (hour, tokens) in state.buckets where hour >= weekStart - 5 {
                merged[hour, default: 0] += tokens
            }
        }

        // Session blocks: a block starts at the first active hour ≥5h after
        // the previous block's start; the current block is live if now is
        // inside blockStart+5h.
        var blockStart: Int?
        for hour in merged.keys.sorted() where merged[hour, default: 0] > 0 {
            if let start = blockStart {
                if hour >= start + 5 { blockStart = hour }
            } else {
                blockStart = hour
            }
        }

        var next = Snapshot()
        next.weekTokens = merged.filter { $0.key >= weekStart }.values.reduce(0, +)
        if let start = blockStart, nowHour < start + 5 {
            next.blockTokens = (start..<(start + 5)).reduce(0) { $0 + (merged[$1] ?? 0) }
            next.blockResetAt = Date(timeIntervalSince1970: Double(start + 5) * 3600)
        }

        DispatchQueue.main.async {
            if self.snapshot != next { self.snapshot = next }
        }
    }
}
