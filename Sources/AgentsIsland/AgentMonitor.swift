import Foundation

/// Polls the process table and Claude Code's session registry, publishing
/// the list of recognized coding agent sessions.
final class AgentMonitor: ObservableObject {
    static let shared = AgentMonitor()

    @Published private(set) var agents: [AgentSession] = []

    private var timer: Timer?
    private var currentInterval: TimeInterval = 0
    private var hasScannedOnce = false
    /// CPU-only agents that just went working → idle; completion fires on the
    /// next scan if they're still idle (one-scan debounce to ride out CPU dips).
    private var pendingCompletion: Set<Int32> = []
    /// Kinds whose status comes from a transcript/registry (real working/waiting),
    /// so they reach `.waiting` and don't need the CPU-idle completion heuristic.
    private static let richStatusKinds: Set<AgentKind> = [.claude, .codex, .gemini]
    private let queue = DispatchQueue(label: "agents-island.scan", qos: .utility)

    func start() {
        scanNow()
        reschedule()
    }

    private func reschedule() {
        let interval = max(1.0, UserDefaults.standard.double(forKey: Pref.pollInterval))
        guard interval != currentInterval else { return }
        currentInterval = interval
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.scanNow()
            self?.reschedule()
        }
    }

    func scanNow() {
        queue.async { [weak self] in
            let found = Self.findAgents()
            DispatchQueue.main.async {
                guard let self else { return }
                self.reschedule()

                // Record that a scan completed *before* the unchanged-list
                // early-return, so launching with zero agents still counts as
                // the first scan — otherwise the first agent to appear later
                // would be mistaken for "already running" and never post
                // .agentStarted / its start sound.
                let firstScan = !self.hasScannedOnce
                self.hasScannedOnce = true
                // Also proceed when a debounced completion is armed — the "still
                // idle" scan that fires it often leaves the list otherwise unchanged.
                guard self.agents != found || !self.pendingCompletion.isEmpty else { return }

                // uniquingKeysWith (not the trapping uniqueKeysWithValues):
                // remote synthetic ids are hashed and could, in theory, collide.
                let previous = Dictionary(self.agents.map { ($0.id, $0.status) },
                                          uniquingKeysWith: { first, _ in first })
                // Suppress lifecycle events on the very first scan — everything
                // already running would otherwise "start" at once.
                if !firstScan {
                    for session in found {
                        let cpuOnly = !Self.richStatusKinds.contains(session.kind)
                        switch (previous[session.id], session.status) {
                        case (nil, _):
                            NotificationCenter.default.post(name: .agentStarted, object: session.id)
                        case (.working, .waiting):
                            NotificationCenter.default.post(name: .agentCompleted, object: session.id)
                        case (.waiting, .working), (.idle, .working):
                            NotificationCenter.default.post(name: .agentAcknowledged, object: session.id)
                        case (.working, .idle) where cpuOnly:
                            // Arm a debounced completion — don't fire yet.
                            self.pendingCompletion.insert(session.id)
                        default:
                            break
                        }
                        // Fire the deferred completion only if the agent is still
                        // idle a scan later (a working flap cancels it).
                        if cpuOnly, self.pendingCompletion.contains(session.id) {
                            if session.status == .working {
                                self.pendingCompletion.remove(session.id)
                            } else if session.status == .idle, previous[session.id] == .idle {
                                NotificationCenter.default.post(name: .agentCompleted, object: session.id)
                                self.pendingCompletion.remove(session.id)
                            }
                        }
                    }
                    let live = Set(found.map(\.id))
                    self.pendingCompletion = self.pendingCompletion.filter { live.contains($0) }
                }
                self.agents = found
                ApprovalCenter.shared.sync(agents: found)
            }
        }
    }

    // MARK: - Scanning

    private struct ProcInfo {
        let ppid: Int32
        let command: String // full path or command name (ps comm)
    }

    private static func findAgents() -> [AgentSession] {
        let disabled = Pref.disabledKinds
        let hideIdleMinutes = UserDefaults.standard.integer(forKey: Pref.hideIdleAfterMinutes)

        // Full process table: pid, ppid, cpu, tty, etime, args — one pass.
        let output = run("/bin/ps", ["-axwwo", "pid=,ppid=,pcpu=,tty=,etime=,args="])
        var procs: [Int32: ProcInfo] = [:]
        var candidates: [(pid: Int32, ppid: Int32, cpu: Double, tty: String?, etime: String, args: String, kind: AgentKind)] = []

        for line in output.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard parts.count == 6,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]),
                  let cpu = Double(parts[2]) else { continue }
            let tty = parts[3] == "??" ? nil : String(parts[3])
            let args = String(parts[5])
            procs[pid] = ProcInfo(ppid: ppid, command: String(args.split(separator: " ").first ?? ""))
            if let kind = detect(args: args), !disabled.contains(kind), !isHeadless(tty: tty, args: args) {
                candidates.append((pid, ppid, cpu, tty, String(parts[4]), args, kind))
            }
        }

        // Drop children whose parent is the same agent (forked helpers).
        let agentKindByPid = Dictionary(uniqueKeysWithValues: candidates.map { ($0.pid, $0.kind) })
        let rows = candidates.filter { agentKindByPid[$0.ppid] != $0.kind }

        let claudeMetas = ClaudeSessions.sessionsByPid()
        let needCwd = rows.filter { $0.kind != .claude || claudeMetas[$0.pid] == nil }.map(\.pid)
        let cwds = cwdByPid(needCwd)

        var sessions: [AgentSession] = []
        for row in rows {
            let bypass = row.args.contains("bypassPermissions")
                || row.args.contains("--dangerously-skip-permissions")
                || row.args.contains("--yolo")
            let terminal = terminalApp(for: row.pid, procs: procs)

            var session = AgentSession(
                id: row.pid,
                kind: row.kind,
                cpu: row.cpu,
                elapsed: prettyElapsed(row.etime),
                cwd: cwds[row.pid],
                status: row.cpu > 3.0 ? .working : .idle,
                terminalApp: terminal,
                tty: row.tty,
                bypassPermissions: bypass
            )

            if row.kind == .claude, let meta = claudeMetas[row.pid] {
                session.cwd = meta.cwd
                let path = ClaudeSessions.transcriptPath(for: meta)
                session.transcriptPath = path
                let info = ClaudeSessions.tailInfo(path: path)
                // meta.name carries a hash suffix ("myproj-0d") — prefer the AI
                // title, then fall back to the clean cwd basename in the view.
                session.title = info.title
                session.lastPrompt = info.lastPrompt
                session.lastMessage = info.lastMessage
                session.model = info.model
                session.subagents = info.subagents
                session.plan = info.plan
                // Task store is the current system; TodoWrite in the
                // transcript is the legacy fallback.
                let storeTasks = ClaudeSessions.tasks(sessionId: meta.sessionId)
                session.todos = storeTasks.isEmpty ? info.todos : storeTasks

                let idleAge = meta.statusUpdatedAt.map {
                    Date().timeIntervalSince1970 - $0 / 1000
                } ?? 0
                if meta.status == "busy" {
                    session.status = .working
                    session.activity = info.activity ?? "Thinking…"
                } else {
                    session.status = idleAge > 30 * 60 ? .idle : .waiting
                    if hideIdleMinutes > 0, idleAge > Double(hideIdleMinutes) * 60 { continue }
                }
            } else if row.kind == .codex,
                      let path = CodexSessions.rolloutPath(pid: row.pid, cwd: cwds[row.pid]) {
                let info = CodexSessions.tailInfo(path: path)
                session.transcriptPath = path
                session.lastPrompt = info.lastPrompt
                session.model = info.model
                session.todos = info.todos

                let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
                let idleAge = mtime.map { Date().timeIntervalSince($0) } ?? 0
                switch info.phase {
                case .working:
                    session.status = .working
                    session.activity = info.activity ?? "Thinking…"
                case .waiting:
                    session.status = idleAge > 30 * 60 ? .idle : .waiting
                    if hideIdleMinutes > 0, idleAge > Double(hideIdleMinutes) * 60 { continue }
                case .unknown:
                    // No task events parsed — trust the CPU heuristic, but
                    // still demote/hide long-quiet sessions by rollout age.
                    if session.status != .working {
                        session.status = idleAge > 30 * 60 ? .idle : .waiting
                        if hideIdleMinutes > 0, idleAge > Double(hideIdleMinutes) * 60 { continue }
                    }
                }
            } else if row.kind == .gemini, let cwd = cwds[row.pid] {
                let info = GeminiSessions.info(cwd: cwd)
                session.lastPrompt = info.lastPrompt
                session.transcriptPath = info.chatPath

                // No task events in Gemini's logs — CPU heuristic, with a
                // grace period right after a prompt (streaming/API waits can
                // briefly drop CPU) and waiting/idle split by prompt age.
                if session.status != .working, let age = info.promptAge {
                    if age < 20 {
                        session.status = .working
                    } else {
                        session.status = age > 30 * 60 ? .idle : .waiting
                        if hideIdleMinutes > 0, age > Double(hideIdleMinutes) * 60 { continue }
                    }
                }
            }

            // Model fallbacks: the command line (-m / --model), then Gemini's
            // settings.json default.
            if session.model == nil { session.model = argsModel(row.args) }
            if session.model == nil, row.kind == .gemini {
                session.model = GeminiSessions.defaultModel()
            }

            // Branch reads touch project folders (often in ~/Documents, which
            // is TCC-protected) — skip them entirely when the chip is off.
            if UserDefaults.standard.bool(forKey: Pref.showGitBranch) {
                session.gitBranch = gitBranch(cwd: session.cwd)
            }
            sessions.append(session)
        }

        sessions.append(contentsOf: RemoteMonitor.shared.currentSessions())

        return sessions.sorted {
            (sortRank($0.status), $0.kind.rawValue, $0.id) < (sortRank($1.status), $1.kind.rawValue, $1.id)
        }
    }

    private static func sortRank(_ status: AgentStatus) -> Int {
        switch status {
        case .working: return 0
        case .waiting: return 1
        case .idle: return 2
        }
    }

    /// Background / programmatic agents: no controlling terminal AND driven over
    /// a piped protocol (`stream-json`) or in print mode (`-p` / `--print`).
    /// These are SDK / orchestrator runs (e.g. FleetView sessions under
    /// ~/.slock/agents) — the island can neither jump to nor reply into them, and
    /// counting them inflates the session badge with sessions the user never
    /// opened in a terminal. Interactive agents always own a pty, so a live tty
    /// keeps them visible.
    private static func isHeadless(tty: String?, args: String) -> Bool {
        guard tty == nil else { return false }
        if args.contains("stream-json") || args.contains("--print") { return true }
        return args.split(separator: " ").contains("-p")
    }

    /// Model from the command line: `-m x`, `--model x`, or `--model=x`.
    static func argsModel(_ args: String) -> String? {
        let tokens = args.split(separator: " ").map(String.init)
        for (index, token) in tokens.enumerated() {
            if token == "-m" || token == "--model",
               index + 1 < tokens.count, !tokens[index + 1].hasPrefix("-") {
                return tokens[index + 1]
            }
            if token.hasPrefix("--model=") { return String(token.dropFirst("--model=".count)) }
        }
        return nil
    }

    /// Recognize an agent from its full command line. Matches the executable
    /// basename directly, or the script argument when run via an interpreter.
    /// Binaries inside .app bundles are GUI apps, not CLI agents — the Claude
    /// Desktop app's binary is literally named "Claude" and would ghost in.
    static func detect(args: String) -> AgentKind? {
        let tokens = args.split(separator: " ")
        guard let first = tokens.first, !first.contains(".app/") else { return nil }
        let exe = basename(String(first))

        if let kind = AgentKind(matching: exe) { return kind }

        let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "uv", "npx"]
        if interpreters.contains(exe.lowercased()) {
            for token in tokens.dropFirst() {
                if token.hasPrefix("-") || token.contains(".app/") { continue }
                if let kind = AgentKind(matching: basename(String(token))) { return kind }
            }
        }
        return nil
    }

    /// Walk up the parent chain to find the hosting terminal / editor app.
    private static func terminalApp(for pid: Int32, procs: [Int32: ProcInfo]) -> String? {
        var current = pid
        for _ in 0..<40 {
            guard let info = procs[current], info.ppid > 1 else { return nil }
            current = info.ppid
            guard let parent = procs[current] else { return nil }

            if let appName = appBundleName(from: parent.command) {
                return appName
            }
            let base = basename(parent.command).lowercased()
            if ["tmux", "screen", "zellij"].contains(base) { return base }
        }
        return nil
    }

    private static func appBundleName(from command: String) -> String? {
        for component in command.split(separator: "/") where component.hasSuffix(".app") {
            var name = String(component.dropLast(4))
            if name == "Visual Studio Code" { name = "VS Code" }
            if name == "iTerm2" { name = "iTerm" }
            return name
        }
        return nil
    }

    private static func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Current git branch of a directory — a couple of tiny file reads, no git
    /// binary. Handles worktrees (`.git` file pointing at the real gitdir).
    private static func gitBranch(cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        var gitPath = cwd + "/.git"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue {
            guard let pointer = try? String(contentsOfFile: gitPath, encoding: .utf8),
                  let dir = pointer.split(separator: ":", maxSplits: 1).last?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !dir.isEmpty
            else { return nil }
            gitPath = dir
        }
        guard let head = try? String(contentsOfFile: gitPath + "/HEAD", encoding: .utf8) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") {
            return String(trimmed.dropFirst("ref: refs/heads/".count))
        }
        return String(trimmed.prefix(7)) // detached HEAD → short hash
    }

    /// One lsof call for all pids: `p<pid>` lines followed by `n<path>` lines.
    private static func cwdByPid(_ pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        let output = run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", list, "-Fn"])

        var result: [Int32: String] = [:]
        var currentPid: Int32?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") {
                currentPid = Int32(line.dropFirst())
            } else if line.hasPrefix("n"), let pid = currentPid {
                result[pid] = String(line.dropFirst())
            }
        }
        return result
    }

    /// ps etime is [[dd-]hh:]mm:ss — condense to "3m", "1h 12m", "2d 4h".
    static func prettyElapsed(_ etime: String) -> String {
        var days = 0
        var rest = etime
        if let dash = rest.firstIndex(of: "-") {
            days = Int(rest[..<dash]) ?? 0
            rest = String(rest[rest.index(after: dash)...])
        }
        let comps = rest.split(separator: ":").compactMap { Int($0) }
        var hours = 0, minutes = 0
        if comps.count == 3 { hours = comps[0]; minutes = comps[1] }
        else if comps.count == 2 { minutes = comps[0] }

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ""
        }
        // Read before waiting so a full pipe buffer can't deadlock us.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
