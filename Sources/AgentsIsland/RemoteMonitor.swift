import Foundation

/// Scans SSH hosts for agent processes and feeds them into the session list.
///
/// v1 scope: one `ps` sweep per host every ~10s over `ssh -o BatchMode=yes`
/// (key auth only — never prompts), with `/proc/<pid>/cwd` for working dirs
/// on Linux. Remote sessions get CPU-heuristic status, a host chip, and
/// negative synthetic ids so they can't collide with local pids. No
/// click-to-jump — the terminal lives on another machine.
final class RemoteMonitor {
    static let shared = RemoteMonitor()

    struct Host: Codable, Equatable, Identifiable {
        var host: String     // "user@server" or ssh-config alias
        var enabled: Bool
        var id: String { host }
    }

    private var timer: Timer?
    private let queue = DispatchQueue(label: "agents-island.remote", qos: .utility)
    private let lock = NSLock()
    private var cache: [AgentSession] = []
    private var reachable: [String: Bool] = [:]

    // MARK: - Host list (stored as JSON in UserDefaults)

    static func hosts() -> [Host] {
        guard let raw = UserDefaults.standard.string(forKey: Pref.sshHosts),
              let data = raw.data(using: .utf8),
              let hosts = try? JSONDecoder().decode([Host].self, from: data)
        else { return [] }
        return hosts
    }

    static func saveHosts(_ hosts: [Host]) {
        guard let data = try? JSONEncoder().encode(hosts),
              let raw = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(raw, forKey: Pref.sshHosts)
        shared.scanSoon()
    }

    /// Last connection result per host, for the settings UI.
    func isReachable(_ host: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return reachable[host]
    }

    // MARK: - Scanning

    func start() {
        scanSoon()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.scanSoon()
        }
    }

    func scanSoon() {
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
        var reach: [String: Bool] = [:]
        for host in hosts {
            if let found = scan(host: host.host) {
                sessions.append(contentsOf: found)
                reach[host.host] = true
            } else {
                reach[host.host] = false
            }
        }
        lock.lock()
        cache = sessions
        reachable = reach
        lock.unlock()
    }

    /// One round-trip: ps for everything + cwd readlinks (Linux) for any
    /// process whose args mention a known agent.
    private func scan(host: String) -> [AgentSession]? {
        let disabled = Pref.disabledKinds
        let remoteCommand = """
        ps axwwo pid=,pcpu=,etime=,args=; \
        for p in /proc/[0-9]*; do \
          c=$(readlink "$p/cwd" 2>/dev/null) || continue; \
          echo "CWD ${p#/proc/} $c"; \
        done 2>/dev/null
        """
        let output = run("/usr/bin/ssh", [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=4",
            "-o", "StrictHostKeyChecking=accept-new",
            host, remoteCommand,
        ])
        guard let output else { return nil }

        var cwds: [Int32: String] = [:]
        var rows: [(pid: Int32, cpu: Double, etime: String, args: String, kind: AgentKind)] = []
        for line in output.split(separator: "\n") {
            if line.hasPrefix("CWD ") {
                let parts = line.dropFirst(4).split(separator: " ", maxSplits: 1)
                if parts.count == 2, let pid = Int32(parts[0]) {
                    cwds[pid] = String(parts[1])
                }
                continue
            }
            let parts = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  let pid = Int32(parts[0]),
                  let cpu = Double(parts[1]) else { continue }
            let args = String(parts[3])
            if let kind = AgentMonitor.detect(args: args), !disabled.contains(kind) {
                rows.append((pid, cpu, String(parts[2]), args, kind))
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

    /// nil = connection failed (unreachable / auth needed).
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
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
