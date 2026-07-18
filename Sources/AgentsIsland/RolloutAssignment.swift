import Foundation

/// Deciding which Codex rollout file belongs to which running process.
///
/// Codex, unlike Claude Code, keeps no pid registry, so the mapping is inferred
/// — from the file the process holds open, or failing that by matching the
/// rollout's recorded cwd. Inferred mappings have to be *retired* when the
/// process exits, and that is the part that was missing: the cache only ever
/// grew, and `fileExists` never expired anything because rollout files are
/// never deleted.
///
/// Split out with no dependencies so both halves are directly testable; the
/// failure they cause is a card confidently showing someone else's
/// conversation, which is worse than showing nothing.
enum RolloutAssignment {

    /// Drop mappings whose process is gone.
    ///
    /// macOS recycles pids aggressively, so a retired entry is not merely
    /// stale — a new codex session can land on that pid and inherit the old
    /// session's rollout.
    static func pruned(_ cache: [Int32: String], livePids: Set<Int32>) -> [Int32: String] {
        cache.filter { livePids.contains($0.key) }
    }

    /// Pick a rollout for a session, preferring one not already claimed.
    ///
    /// `candidates` is newest-first. Falling back to the newest claimed rollout
    /// is deliberate: two codex processes in one directory is unusual, and
    /// showing the most recent conversation beats showing none. That fallback
    /// is only sound when `assigned` reflects live processes — see `pruned`.
    static func select(candidates: [String], assigned: Set<String>) -> String? {
        candidates.first { !assigned.contains($0) } ?? candidates.first
    }
}
