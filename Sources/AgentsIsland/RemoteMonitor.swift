import Foundation
import Combine

/// Scans SSH hosts for agent processes and feeds them into the session list.
///
/// v1 scope: one `ps` sweep per host every ~10s over `ssh -o BatchMode=yes`
/// (key auth only — never prompts), with `/proc/<pid>/cwd` for working dirs
/// on Linux. Remote sessions get CPU-heuristic status, a host chip, and
/// negative synthetic ids so they can't collide with local pids. No
/// click-to-jump — the terminal lives on another machine.
///
/// It publishes live per-host connection status (`ObservableObject`) so the
/// Settings screen can show which devices are actually connected and how many
/// remote jobs each is running, rather than a one-shot text label.
final class RemoteMonitor: ObservableObject {
    static let shared = RemoteMonitor()

    struct Host: Codable, Equatable, Identifiable {
        var host: String     // "user@server" or ssh-config alias
        var enabled: Bool
        var id: String { host }
    }

    /// Live connection state for one host, surfaced to the Settings UI.
    struct HostStatus: Equatable {
        enum Reachability: Equatable { case unknown, checking, connected, unreachable }
        var reachability: Reachability = .unknown
        var sessionCount: Int = 0
        var lastChecked: Date?
    }

    /// Per-host status, updated on the main thread after every scan.
    @Published private(set) var status: [String: HostStatus] = [:]

    private var timer: Timer?
    private let queue = DispatchQueue(label: "agents-island.remote", qos: .utility)
    private let lock = NSLock()
    private var cache: [AgentSession] = []

    // MARK: - Host list (stored as JSON in UserDefaults)

    static func hosts() -> [Host] {
        guard let raw = UserDefaults.standard.string(forKey: Pref.sshHosts),
              let data = raw.data(using: .utf8),
              let hosts = try? JSONDecoder().decode([Host].self, from: data)
        else { return [] }
        return hosts
    }

    /// Clean a host string into something `ssh` accepts. Users paste whole
    /// commands ("ssh macbook") or add stray whitespace — strip a leading
    /// `ssh ` and surrounding spaces so the alias/host actually resolves.
    static func normalize(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespaces)
        while h.lowercased().hasPrefix("ssh ") {
            h = String(h.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }
        return h
    }

    static func saveHosts(_ hosts: [Host]) {
        // Normalize + de-dupe so a malformed "ssh macbook" never reaches ssh.
        var seen = Set<String>()
        let cleaned = hosts.compactMap { host -> Host? in
            let name = normalize(host.host)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return Host(host: name, enabled: host.enabled)
        }
        guard let data = try? JSONEncoder().encode(cleaned),
              let raw = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(raw, forKey: Pref.sshHosts)
        // Drop status for hosts that no longer exist so the UI doesn't show ghosts.
        let live = Set(cleaned.map(\.host))
        DispatchQueue.main.async {
            shared.status = shared.status.filter { live.contains($0.key) }
        }
        shared.scanSoon()
    }

    /// Host aliases declared in ~/.ssh/config (concrete hosts only — wildcard
    /// patterns are skipped). Lets the user pick a configured host instead of
    /// retyping `user@server`.
    static func sshConfigHosts() -> [String] {
        let path = FileManager.default.homeDirectoryForCurrentUser.path + "/.ssh/config"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var aliases: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("host ") else { continue }
            let names = trimmed.dropFirst(5).split(separator: " ")
            for name in names where !name.contains("*") && !name.contains("?") {
                aliases.append(String(name))
            }
        }
        // Stable, de-duplicated, in file order.
        var seen = Set<String>()
        return aliases.filter { seen.insert($0).inserted }
    }

    // MARK: - Scanning

    func start() {
        // One-time cleanup: rewrite any malformed stored hosts through normalize
        // (e.g. a "ssh macbook" typo becomes "macbook") so scans actually resolve.
        let stored = Self.hosts()
        let migrated = stored.map { Host(host: Self.normalize($0.host), enabled: $0.enabled) }
        if migrated != stored { Self.saveHosts(migrated) }
        scanSoon()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.scanSoon()
        }
    }

    func scanSoon() {
        queue.async { [weak self] in self?.scanAll() }
    }

    /// Force an immediate re-scan of one host and mark it "checking" right away
    /// so the Settings row gives instant feedback on a "Test" tap.
    func testConnection(host: String) {
        publish(host: host) { $0.reachability = .checking }
        queue.async { [weak self] in self?.scanAll() }
    }

    /// Thread-safe snapshot merged by AgentMonitor on every local scan.
    func currentSessions() -> [AgentSession] {
        lock.lock(); defer { lock.unlock() }
        return cache
    }

    private func scanAll() {
        let hosts = Self.hosts().filter(\.enabled)
        var sessions: [AgentSession] = []
        var freshStatus: [String: HostStatus] = [:]
        let now = Date()
        for host in hosts {
            if let found = scan(host: host.host) {
                sessions.append(contentsOf: found)
                freshStatus[host.host] = HostStatus(
                    reachability: .connected, sessionCount: found.count, lastChecked: now)
            } else {
                freshStatus[host.host] = HostStatus(
                    reachability: .unreachable, sessionCount: 0, lastChecked: now)
            }
        }
        lock.lock()
        cache = sessions
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            // Only publish hosts that are still enabled+present; a disabled host
            // keeps whatever the UI wants to show for it.
            self?.status = freshStatus
        }
    }

    private func publish(host: String, _ mutate: @escaping (inout HostStatus) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var current = self.status[host] ?? HostStatus()
            mutate(&current)
            self.status[host] = current
        }
    }

    /// One round-trip: ps for everything + cwd readlinks (Linux) for any
    /// process whose args mention a known agent.
    private func scan(host: String) -> [AgentSession]? {
        let disabled = Pref.disabledKinds
        // The trailing sentinel only prints if `ps` itself succeeded, so we can
        // tell "connected but no agents" apart from "connected but ps failed"
        // (which would otherwise masquerade as a healthy empty host).
        let remoteCommand = """
        ps axwwo pid=,ppid=,pcpu=,etime=,args= && echo __AI_SCAN_OK__; \
        for p in /proc/[0-9]*; do \
          c=$(readlink "$p/cwd" 2>/dev/null) || continue; \
          echo "CWD ${p#/proc/} $c"; \
        done 2>/dev/null
        """
        let output = run("/usr/bin/ssh", [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=4",
            // Bound the whole session, not just the connect: a post-connect hang
            // (dead network, wedged sshd) is torn down after ~6s instead of
            // stalling the serial scan queue forever.
            "-o", "ServerAliveInterval=3",
            "-o", "ServerAliveCountMax=2",
            "-o", "StrictHostKeyChecking=accept-new",
            host, remoteCommand,
        ])
        // nil = connection failed; missing sentinel = shell/ps broke → unreachable.
        guard let output, output.contains("__AI_SCAN_OK__") else { return nil }

        var cwds: [Int32: String] = [:]
        var candidates: [(pid: Int32, ppid: Int32, cpu: Double, etime: String, args: String, kind: AgentKind)] = []
        for line in output.split(separator: "\n") {
            if line.hasPrefix("CWD ") {
                let parts = line.dropFirst(4).split(separator: " ", maxSplits: 1)
                if parts.count == 2, let pid = Int32(parts[0]) {
                    cwds[pid] = String(parts[1])
                }
                continue
            }
            let parts = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]),
                  let cpu = Double(parts[2]) else { continue }
            let args = String(parts[4])
            if let kind = AgentMonitor.detect(args: args), !disabled.contains(kind) {
                candidates.append((pid, ppid, cpu, String(parts[3]), args, kind))
            }
        }

        // Same fork dedup the local scan does: a coding agent spawns child
        // processes of its own kind (node → node …). Without this, one remote
        // session shows up as several — the exact over-count we fix locally.
        let kindByPid = Dictionary(candidates.map { ($0.pid, $0.kind) }, uniquingKeysWith: { first, _ in first })
        let rows = candidates.filter { kindByPid[$0.ppid] != $0.kind }

        // macOS remotes have no /proc, so the cwd loop above found nothing there.
        // Fetch just the agent cwds with a targeted lsof (one extra round-trip,
        // only when a session is missing its directory).
        let missing = rows.filter { cwds[$0.pid] == nil }.map { String($0.pid) }
        if !missing.isEmpty, let out = run("/usr/bin/ssh", [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=4",
            "-o", "ServerAliveInterval=3", "-o", "ServerAliveCountMax=2",
            "-o", "StrictHostKeyChecking=accept-new",
            host, "lsof -a -d cwd -p \(missing.joined(separator: ",")) -Fn 2>/dev/null",
        ]) {
            var currentPid: Int32?
            for line in out.split(separator: "\n") {
                if line.hasPrefix("p") { currentPid = Int32(line.dropFirst()) }
                else if line.hasPrefix("n"), let pid = currentPid { cwds[pid] = String(line.dropFirst()) }
            }
        }

        return rows.map { row in
            let bypass = row.args.contains("bypassPermissions")
                || row.args.contains("--dangerously-skip-permissions")
                || row.args.contains("--yolo")
            var session = AgentSession(
                id: Self.syntheticId(host: host, pid: row.pid),
                kind: row.kind,
                cpu: row.cpu,
                elapsed: AgentMonitor.prettyElapsed(row.etime),
                cwd: cwds[row.pid],
                status: row.cpu > 3.0 ? .working : .idle,
                terminalApp: nil, // no local terminal to jump to
                tty: nil,
                bypassPermissions: bypass
            )
            session.remoteHost = host
            session.model = AgentMonitor.argsModel(row.args)
            return session
        }
    }

    /// Stable-within-launch negative id — never collides with local pids.
    private static func syntheticId(host: String, pid: Int32) -> Int32 {
        var hash: UInt32 = 5381
        for byte in "\(host):\(pid)".utf8 {
            hash = hash &* 33 &+ UInt32(byte)
        }
        return -Int32(hash % UInt32(Int32.max - 1)) - 1
    }

    /// Returns whatever the ssh process wrote to stdout, or nil if it couldn't
    /// even launch. We deliberately do NOT gate on the exit status: a fully
    /// successful remote scan can still exit non-zero — e.g. on a macOS host the
    /// `/proc/[0-9]*` cwd loop's glob doesn't expand and the trailing readlink
    /// fails, poisoning the command's exit code even though `ps` ran fine. The
    /// caller's `__AI_SCAN_OK__` sentinel is the real success signal; a failed
    /// connection / auth produces no sentinel (and usually empty stdout) anyway.
    private func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
