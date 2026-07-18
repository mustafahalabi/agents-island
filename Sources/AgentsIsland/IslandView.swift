import SwiftUI

struct IslandView: View {
    @ObservedObject var monitor: AgentMonitor
    @ObservedObject private var switcher = SwitcherState.shared
    let notch: NotchMetrics

    @State private var expanded = false
    @State private var selectedPid: Int32?
    @State private var mouseInside = false
    @State private var hoverToken = 0
    @State private var autoRevealToken = 0
    @State private var autoRevealActive = false
    @State private var outsideClickMonitor: Any?

    @AppStorage(Pref.autoCollapse) private var autoCollapse = true
    @AppStorage(Pref.autoHideWhenEmpty) private var autoHideWhenEmpty = false
    @AppStorage(Pref.expandOnHover) private var expandOnHover = true
    @AppStorage(Pref.hoverDuration) private var hoverDuration = 0.15
    @AppStorage(Pref.smartSuppression) private var smartSuppression = true
    @AppStorage(Pref.autoRevealOnComplete) private var autoRevealOnComplete = true
    @AppStorage(Pref.autoRevealDwell) private var autoRevealDwell = 5.0
    @AppStorage(Pref.dismissRevealOnOutsideClick) private var dismissOnOutsideClick = false
    @AppStorage(Pref.disableClickToJump) private var disableClickToJump = false
    @AppStorage(Pref.maxVisibleSessions) private var maxVisible = 6
    @AppStorage(Pref.pillStyle) private var pillStyle = "clean"
    @AppStorage(Pref.maxPanelWidth) private var panelWidth = 530.0
    @AppStorage(Pref.maxPanelHeight) private var panelMaxHeight = 560.0

    private var spring: Animation { .spring(response: 0.42, dampingFraction: 0.78) }
    // Opening: slow, fluid, gentle overshoot — the Apple feel.
    private var expandSpring: Animation { .spring(response: 0.55, dampingFraction: 0.76) }
    // Closing: quicker and fully damped, no bounce on the way out.
    private var collapseSpring: Animation { .spring(response: 0.38, dampingFraction: 0.92) }
    private var hidden: Bool { autoHideWhenEmpty && monitor.agents.isEmpty && !expanded }
    private var selectedAgent: AgentSession? {
        selectedPid.flatMap { pid in monitor.agents.first { $0.id == pid } }
    }

    var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var anyWorking: Bool { monitor.agents.contains { $0.status == .working } }

    private var collapsedWidth: CGFloat {
        notch.width + (pillStyle == "detailed" ? 440 : 180)
    }

    private var island: some View {
        ZStack(alignment: .top) {
            if expanded {
                expandedBody
                    .frame(width: panelWidth)
                    .transition(.islandContent)
            } else {
                CollapsedContent(agents: monitor.agents, notch: notch, detailed: pillStyle == "detailed")
                    .frame(width: collapsedWidth, height: notch.height + 1)
                    .transition(.islandContent)
            }
        }
        .background(islandBackground)
        .geometryGroup()
        .opacity(hidden ? 0 : 1)
        .allowsHitTesting(!hidden)
        .onHover(perform: handleHover)
        .animation(spring, value: monitor.agents)
        .onReceive(NotificationCenter.default.publisher(for: .agentCompleted), perform: handleCompletion)
        .onReceive(NotificationCenter.default.publisher(for: .approvalNeeded), perform: handleApprovalNeeded)
        .onReceive(NotificationCenter.default.publisher(for: .islandExpand)) { _ in
            guard !expanded else { return }
            withAnimation(expandSpring) { expanded = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .islandCollapse)) { _ in
            collapseNow()
        }
    }

    // MARK: - Hover / reveal choreography

    private func handleHover(_ hovering: Bool) {
        mouseInside = hovering
        hoverToken += 1
        let token = hoverToken
        if hovering {
            // Entering the island during an auto-reveal keeps it open.
            if autoRevealActive { endAutoReveal() }
            guard expandOnHover, !expanded else { return }
            // Brief intent delay so a cursor passing by doesn't trigger it.
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.02, hoverDuration)) {
                guard token == hoverToken, mouseInside, !expanded else { return }
                withAnimation(expandSpring) { expanded = true }
            }
        } else if autoCollapse, !autoRevealActive, !switcher.active {
            // Grace period prevents flicker at the island's edge.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard token == hoverToken, !mouseInside, !switcher.active else { return }
                collapseNow()
            }
        }
    }

    private func handleCompletion(_ note: Notification) {
        guard autoRevealOnComplete, !expanded else { return }
        // Smart suppression: you're already looking at that agent's terminal.
        if smartSuppression,
           let pid = note.object as? Int32,
           let agent = monitor.agents.first(where: { $0.id == pid }),
           TerminalBridge.isFrontmost(appNamed: agent.terminalApp) {
            return
        }
        withAnimation(expandSpring) { expanded = true }
        autoRevealActive = true
        autoRevealToken += 1
        let token = autoRevealToken
        installOutsideClickMonitor()
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, autoRevealDwell)) {
            guard token == autoRevealToken, autoRevealActive else { return }
            if !mouseInside, !switcher.active { collapseNow() } else { endAutoReveal() }
        }
    }

    /// Approvals always pull the panel forward (independent of the
    /// task-complete toggle) — unless you're already in that terminal.
    private func handleApprovalNeeded(_ note: Notification) {
        guard !expanded else { return }
        if smartSuppression,
           let pid = note.object as? Int32,
           let agent = monitor.agents.first(where: { $0.id == pid }),
           TerminalBridge.isFrontmost(appNamed: agent.terminalApp) {
            return
        }
        withAnimation(expandSpring) { expanded = true }
        autoRevealActive = true
        autoRevealToken += 1
        let token = autoRevealToken
        installOutsideClickMonitor()
        DispatchQueue.main.asyncAfter(deadline: .now() + max(10, autoRevealDwell)) {
            guard token == autoRevealToken, autoRevealActive else { return }
            if !mouseInside, !switcher.active { collapseNow() } else { endAutoReveal() }
        }
    }

    private func collapseNow() {
        withAnimation(collapseSpring) { expanded = false; selectedPid = nil }
        endAutoReveal()
    }

    private func endAutoReveal() {
        autoRevealActive = false
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    /// Clicking anywhere else (another app, the desktop) closes an auto-reveal.
    private func installOutsideClickMonitor() {
        guard dismissOnOutsideClick, outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { _ in
            if autoRevealActive { collapseNow() }
        }
    }

    // MARK: - Background

    private var islandBackground: some View {
        let shape = NotchShape(
            topRadius: expanded ? 14 : 9,
            bottomRadius: expanded ? 30 : 12
        )
        return shape
            .fill(LinearGradient(
                colors: [Color(white: 0.01), Color(white: expanded ? 0.055 : 0.03)],
                startPoint: .top, endPoint: .bottom
            ))
            .overlay(
                // Hairline edge highlight — reads as machined depth.
                shape.stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.02), .white.opacity(expanded ? 0.14 : 0.09)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .padding(0.5)
            )
            .shadow(color: .black.opacity(expanded ? 0.6 : 0.35),
                    radius: expanded ? 24 : 8, y: expanded ? 8 : 3)
            .shadow(color: AgentStatus.working.color.opacity(anyWorking ? (expanded ? 0.10 : 0.16) : 0),
                    radius: expanded ? 30 : 14, y: 6)
    }

    // MARK: - Expanded content

    @ViewBuilder
    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let agent = selectedAgent {
                SessionDetail(agent: agent) {
                    withAnimation(spring) { selectedPid = nil }
                }
            } else {
                header
                sessionList
            }
        }
        .padding(.top, notch.hasNotch ? notch.height + 4 : 12)
        .padding(.horizontal, 22) // clear the top-corner flares
        .padding(.bottom, 16)
    }

    private var header: some View {
        let working = monitor.agents.filter { $0.status == .working }.count
        let waiting = monitor.agents.filter { $0.status == .waiting }.count
        return HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.25))

            HStack(spacing: 5) {
                Circle().fill(AgentStatus.working.color).frame(width: 6, height: 6)
                Text("\(working) working")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(working > 0 ? 0.85 : 0.4))
            }
            HStack(spacing: 5) {
                Circle().fill(AgentStatus.waiting.color).frame(width: 6, height: 6)
                Text("\(waiting) waiting")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(waiting > 0 ? 0.85 : 0.4))
            }

            Spacer()

            if switcher.active {
                Text("↑↓ select · ⏎ jump · esc close")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                UsageHeaderChip()
            }

            Button(action: openSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 2)
    }

    private var sessionList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 7) {
                if monitor.agents.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(monitor.agents.prefix(maxVisible).enumerated()), id: \.element.id) { index, agent in
                        SessionCard(agent: agent,
                                    selected: switcher.active && switcher.index == index) {
                            withAnimation(spring) { selectedPid = agent.id }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { handleCardTap(agent) }
                        .staggeredEntrance(index: index)
                    }
                    if monitor.agents.count > maxVisible {
                        Text("+ \(monitor.agents.count - maxVisible) more")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 2)
                    }
                }
            }
            .background(HeightReader())
        }
        .onPreferenceChange(ContentHeightKey.self) { listContentHeight = $0 }
        .frame(height: min(max(listContentHeight, 40), panelMaxHeight))
    }

    @State private var listContentHeight: CGFloat = 200

    private func handleCardTap(_ agent: AgentSession) {
        // Click = go to the agent's terminal (unless disabled in settings).
        // Details live behind the chevron button on the card.
        if !disableClickToJump, agent.terminalApp != nil {
            TerminalBridge.jump(to: agent)
        } else {
            withAnimation(spring) { selectedPid = agent.id }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.35))
            Text("No agents running")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text("Launch claude, codex, gemini… in a terminal")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private func openSettings() {
        SettingsWindowController.shared.show()
    }
}

/// Vibe-style quota estimate in the header: "5h 34% · ⟳1h20m · 7d 61%".
private struct UsageHeaderChip: View {
    @ObservedObject private var tracker = UsageTracker.shared
    @AppStorage(Pref.usageEnabled) private var enabled = true
    @AppStorage(Pref.usagePlan) private var plan = "max5x"

    private var hasClaude: Bool { tracker.snapshot.weekTokens > 0 }
    private var hasCodex: Bool { tracker.codex.hasData }

    var body: some View {
        if enabled, hasClaude || hasCodex {
            HStack(spacing: 8) {
                if hasClaude { claudeSegment }
                if hasClaude, hasCodex {
                    Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 9)
                }
                if hasCodex { codexSegment }
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
        }
    }

    /// Claude — estimated from transcripts (brand-orange dot).
    private var claudeSegment: some View {
        let budgets = UsageTracker.budgets(plan: plan)
        let snapshot = tracker.snapshot
        return HStack(spacing: 5) {
            Circle().fill(AgentKind.claude.color).frame(width: 5, height: 5)
            if let blockPercent = snapshot.blockPercent(budget: budgets.block),
               let reset = snapshot.blockResetAt {
                label("5h"); percent(blockPercent)
                Text("⟳\(countdown(to: reset))").foregroundStyle(.white.opacity(0.35))
            }
            label("7d"); percent(snapshot.weekPercent(budget: budgets.week))
        }
        .help("Estimated Claude usage — Settings → Usage")
    }

    /// Codex — exact, from its own rate-limit reports (brand-green dot).
    private var codexSegment: some View {
        HStack(spacing: 5) {
            Circle().fill(AgentKind.codex.color).frame(width: 5, height: 5)
            if let secondary = tracker.codex.secondary {
                label(secondary.label); percent(Int(secondary.usedPercent.rounded()))
            }
            if let primary = tracker.codex.primary {
                label(primary.label); percent(Int(primary.usedPercent.rounded()))
            }
        }
        .help("Codex usage — exact, from ~/.codex")
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.white.opacity(0.35))
    }

    private func percent(_ value: Int) -> some View {
        Text("\(min(value, 999))%").foregroundStyle(color(for: value))
    }

    private func color(for percent: Int) -> Color {
        percent >= 90 ? Color(red: 1.0, green: 0.45, blue: 0.45)
            : percent >= 70 ? AgentStatus.waiting.color
            : .white.opacity(0.6)
    }

    private func countdown(to date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

/// Measures the session list so the panel hugs content up to the height cap.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct HeightReader: View {
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
        }
    }
}

// MARK: - Collapsed pill

private struct CollapsedContent: View {
    let agents: [AgentSession]
    let notch: NotchMetrics
    let detailed: Bool

    private var overall: AgentStatus {
        agents.contains { $0.status == .working } ? .working
            : agents.contains { $0.status == .waiting } ? .waiting : .idle
    }

    /// One-liner for the detailed pill: live activity beats waiting beats count.
    private var headline: String {
        if let working = agents.first(where: { $0.status == .working }) {
            return working.activity ?? working.displayTitle
        }
        let waiting = agents.filter { $0.status == .waiting }.count
        if waiting > 0 { return "\(waiting) waiting for you" }
        if let first = agents.first { return first.displayTitle }
        return "No agents"
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left wing: mascot (+ count or live headline), tucked to the edge.
            HStack(spacing: 6) {
                PixelBotView(status: overall, size: 15)
                if detailed {
                    Text(headline)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("\(agents.count)")
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .contentTransition(.numericText())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 20)

            // Leave the physical notch area empty.
            Color.clear
                .frame(width: notch.hasNotch ? notch.width : 8)

            // Right wing: session count (detailed) or one status dot per agent.
            HStack(spacing: 4.5) {
                if detailed {
                    Text("\(agents.count)")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.92))
                        .contentTransition(.numericText())
                    Text(agents.count == 1 ? "session" : "sessions")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                } else if agents.isEmpty {
                    Circle().fill(.white.opacity(0.25)).frame(width: 5.5, height: 5.5)
                } else {
                    ForEach(agents.prefix(4)) { agent in
                        PulsingDot(color: agent.status.color, active: agent.status == .working)
                    }
                    if agents.count > 4 {
                        Text("+\(agents.count - 4)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 20)
        }
    }
}

// MARK: - Session card

private struct SessionCard: View {
    let agent: AgentSession
    var selected = false
    let onShowDetail: () -> Void

    @AppStorage(Pref.showLastPrompt) private var showLastPrompt = true
    @AppStorage(Pref.showActivity) private var showActivity = true
    @AppStorage(Pref.showTerminalChip) private var showTerminalChip = true
    @AppStorage(Pref.showTasks) private var showTasks = true
    @AppStorage(Pref.showModel) private var showModel = true
    @AppStorage(Pref.showGitBranch) private var showGitBranch = true
    @AppStorage(Pref.showSubagents) private var showSubagents = true
    @AppStorage(Pref.contentFontSize) private var fontSize = 11
    @ObservedObject private var approvals = ApprovalCenter.shared
    @State private var hovered = false
    @State private var replyText = ""
    @State private var justSent = false

    private var fs: CGFloat { CGFloat(fontSize) }
    private var approval: ApprovalCenter.Approval? { approvals.pending[agent.id] }
    private var approvalColor: Color { AgentStatus.waiting.color }
    /// The agent is waiting on you and we can type back into its terminal.
    private var canReply: Bool {
        agent.status == .waiting && agent.terminalApp != nil && approval == nil
    }

    /// Live question from the PreToolUse hook — the only real-time source
    /// (the transcript records AskUserQuestion only after it's answered).
    private var liveQuestion: PendingQuestion? { approvals.questions[agent.id]?.question }

    /// A pending question/approval means "waiting on you" regardless of the
    /// flickery CPU/registry status — pin the card's color to that.
    private var effectiveStatus: AgentStatus {
        (approval != nil || liveQuestion != nil) ? .waiting : agent.status
    }

    /// A subtle wash of the status color behind the card (idle stays neutral).
    private var statusWash: Color {
        switch effectiveStatus {
        case .working, .waiting: return effectiveStatus.color.opacity(hovered || selected ? 0.14 : 0.10)
        case .idle:              return .clear
        }
    }

    /// Border color: selected wins, otherwise a status tint.
    private var borderColor: Color {
        if selected { return Color(red: 0.45, green: 0.62, blue: 1.0).opacity(0.8) }
        switch effectiveStatus {
        case .working, .waiting: return effectiveStatus.color.opacity(0.4)
        case .idle:              return .white.opacity(0.07)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentIconView(kind: agent.kind, status: agent.status, size: 26)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                // Line 1: title · detail button · time
                HStack(spacing: 8) {
                    Text(agent.displayTitle)
                        .font(.system(size: fs + 2, weight: .semibold))
                        .foregroundStyle(.white.opacity(agent.status == .idle ? 0.6 : 1))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if hovered {
                        Button(action: onShowDetail) {
                            Image(systemName: "chevron.right.circle.fill")
                                .font(.system(size: fs + 2))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .help("Show conversation")
                    }
                    Text(agent.elapsed)
                        .font(.system(size: fs - 1, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.35))
                        .fixedSize()
                }

                // Line 2: when the agent is waiting on you, surface its question;
                // otherwise show your last message.
                if agent.status == .waiting, let question = agent.lastMessage, approval == nil {
                    Text(question)
                        .font(.system(size: fs))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(3)
                } else if showLastPrompt, let prompt = agent.lastPrompt {
                    Text("You: \(prompt)")
                        .font(.system(size: fs))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(2)
                }

                // Line 3: live status on the left, chips on the right
                HStack(alignment: .center, spacing: 8) {
                    statusLine
                    Spacer(minLength: 8)
                    chips
                }
                .padding(.top, 1)

                // Task checklist from the agent's todo list
                if showTasks, !agent.todos.isEmpty {
                    TasksSection(todos: agent.todos, compact: true)
                        .padding(.top, 3)
                }

                // Fan-out subagents (only interesting while any is running)
                if showSubagents, agent.subagents.contains(where: { !$0.done }) {
                    SubagentsSection(subagents: agent.subagents, compact: true)
                        .padding(.top, 3)
                }

                // Pending permission request → answer from the island.
                if approval != nil {
                    approvalBar
                        .padding(.top, 3)
                } else if let question = liveQuestion, agent.terminalApp != nil {
                    // Structured question, live from the PreToolUse hook —
                    // stays up until the answer lands (PostToolUse / busy).
                    questionBar(question)
                        .padding(.top, 3)
                } else if canReply, hovered || selected {
                    // Free-text question → answer inline without leaving.
                    replyBar
                        .padding(.top, 3)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.white.opacity(selected ? 0.08 : hovered ? 0.06 : 0.03))
                .overlay(  // a wash of the status color so the card reads at a glance
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(statusWash)
                )
        )
        .overlay(  // status-tinted left accent bar
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(effectiveStatus.color.opacity(effectiveStatus == .idle ? 0.3 : 0.9))
                    .frame(width: 3)
                    .padding(.vertical, 10)
                Spacer(minLength: 0)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(borderColor, lineWidth: selected || approval != nil ? 1.5 : 1)
        )
        .onHover { inside in
            hovered = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    /// "Needs approval: Bash" + Approve / Always / Deny, answering the
    /// terminal prompt (1 / 2 / 3) without leaving the island.
    private var approvalBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(approvalColor)
                Text(approval?.toolName.map { "Needs approval: \($0)" } ?? "Needs your approval")
                    .font(.system(size: fs, weight: .semibold))
                    .foregroundStyle(approvalColor)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                ApprovalButton(label: "Approve", tint: AgentStatus.working.color) {
                    ApprovalCenter.shared.respond(pid: agent.id, action: .approve)
                }
                ApprovalButton(label: "Always Allow", tint: .white.opacity(0.75)) {
                    ApprovalCenter.shared.respond(pid: agent.id, action: .alwaysAllow)
                }
                ApprovalButton(label: "Deny", tint: Color(red: 1.0, green: 0.45, blue: 0.45)) {
                    ApprovalCenter.shared.respond(pid: agent.id, action: .deny)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(approvalColor.opacity(0.10)))
    }

    /// Answer the agent's question straight into its terminal, without opening
    /// the detail view or switching to the terminal.
    private var replyBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 10))
                .foregroundStyle(AgentStatus.waiting.color)
            TextField("Answer \(agent.kind.displayName)…", text: $replyText)
                .textFieldStyle(.plain)
                .font(.system(size: fs))
                .foregroundStyle(.white)
                .onSubmit(sendReply)
            Button(action: sendReply) {
                Image(systemName: justSent ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(justSent ? AgentStatus.working.color
                        : replyText.trimmingCharacters(in: .whitespaces).isEmpty
                            ? .white.opacity(0.3)
                            : Color(red: 0.45, green: 0.62, blue: 1.0))
            }
            .buttonStyle(.plain)
            .disabled(replyText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(AgentStatus.waiting.color.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(AgentStatus.waiting.color.opacity(0.25), lineWidth: 1))
    }

    private func sendReply() {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        TerminalBridge.send(text: text, to: agent)
        replyText = ""
        justSent = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { justSent = false }
    }

    /// A structured AskUserQuestion → one tappable button per option, plus a
    /// free-text box for a custom ("Other") answer.
    private func questionBar(_ question: PendingQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(AgentStatus.waiting.color)
                Text(question.prompt)
                    .font(.system(size: fs, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                if question.multiSelect {
                    Text("· pick any")
                        .font(.system(size: fs - 2))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            ForEach(Array(question.options.prefix(6).enumerated()), id: \.offset) { index, option in
                Button { answerChoice(index + 1) } label: {
                    HStack(spacing: 7) {
                        Text("\(index + 1)")
                            .font(.system(size: fs - 1, weight: .bold, design: .rounded))
                            .foregroundStyle(AgentStatus.waiting.color)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(AgentStatus.waiting.color.opacity(0.18)))
                        Text(option)
                            .font(.system(size: fs))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(0.06)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            replyBar // "Other" — type a custom answer
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(AgentStatus.waiting.color.opacity(0.10)))
    }

    /// Answer a choice: the digit selects the option in Claude's prompt and
    /// Enter confirms it (TerminalBridge.send types text + Enter).
    private func answerChoice(_ number: Int) {
        ApprovalCenter.shared.clearQuestion(pid: agent.id)
        DispatchQueue.global(qos: .userInitiated).async {
            TerminalBridge.send(text: String(number), to: agent)
        }
        justSent = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { justSent = false }
    }

    /// Chips drop least-important-first when the row runs out of width, so
    /// they never squeeze the status text into vertical wrapping.
    private var chips: some View {
        ViewThatFits(in: .horizontal) {
            chipRow(model: showModel, branch: showGitBranch, terminal: showTerminalChip)
            chipRow(model: showModel, branch: showGitBranch, terminal: false)
            chipRow(model: false, branch: showGitBranch, terminal: false)
            chipRow(model: false, branch: false, terminal: false)
        }
    }

    private func chipRow(model: Bool, branch: Bool, terminal: Bool) -> some View {
        HStack(spacing: 4) {
            if agent.bypassPermissions {
                Chip(text: "BYPASS",
                     textColor: Color(red: 1.0, green: 0.5, blue: 0.5),
                     background: Color(red: 1.0, green: 0.3, blue: 0.3).opacity(0.15))
            }
            Chip(text: agent.kind.displayName,
                 textColor: .white.opacity(0.85),
                 background: agent.kind.color.opacity(0.25))
            if model, let name = agent.modelDisplay {
                Chip(text: name, textColor: .white.opacity(0.75), background: .white.opacity(0.08))
            }
            if branch, let name = agent.gitBranch {
                // Long branch names would crowd out the status line.
                Chip(text: name.count > 16 ? name.prefix(15) + "…" : name,
                     textColor: .white.opacity(0.65), background: .white.opacity(0.08),
                     icon: "arrow.triangle.branch")
            }
            if terminal, let app = agent.terminalApp {
                Chip(text: app, textColor: .white.opacity(0.65), background: .white.opacity(0.08))
            }
            if let host = agent.remoteHost {
                Chip(text: host, textColor: Color(red: 0.55, green: 0.80, blue: 1.0),
                     background: Color(red: 0.3, green: 0.55, blue: 0.9).opacity(0.18),
                     icon: "network")
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var statusLine: some View {
        if agent.status == .working, showActivity, let activity = agent.activity {
            Text(activity)
                .font(.system(size: fs, weight: .medium))
                .foregroundStyle(Color(red: 0.45, green: 0.62, blue: 1.0))
                .lineLimit(1)
        } else if agent.status == .waiting {
            Text("Waiting for you")
                .font(.system(size: fs, weight: .medium))
                .foregroundStyle(AgentStatus.waiting.color.opacity(0.9))
                .lineLimit(1)
                .fixedSize()
        } else {
            Text(agent.status == .idle ? "Idle" : agent.status.label)
                .font(.system(size: fs, weight: .medium))
                .foregroundStyle(.white.opacity(0.3))
                .lineLimit(1)
                .fixedSize()
        }
    }
}

private struct ApprovalButton: View {
    let label: String
    let tint: Color
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(tint.opacity(hovered ? 0.22 : 0.12)))
                .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct Chip: View {
    let text: String
    let textColor: Color
    let background: Color
    var icon: String?

    var body: some View {
        HStack(spacing: 2.5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .semibold))
            }
            Text(text)
        }
        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
        .foregroundStyle(textColor)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(background))
    }
}

// MARK: - Session detail (click a card)

private struct SessionDetail: View {
    let agent: AgentSession
    let onBack: () -> Void

    @State private var messages: [ChatMessage] = []
    @State private var replyText = ""
    @State private var justSent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.white.opacity(0.1)))
                }
                .buttonStyle(.plain)

                AgentIconView(kind: agent.kind, status: agent.status, size: 20)

                Text(agent.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer()

                Chip(text: agent.kind.displayName,
                     textColor: .white.opacity(0.85),
                     background: agent.kind.color.opacity(0.28))
                if let terminal = agent.terminalApp {
                    Button {
                        TerminalBridge.jump(to: agent)
                    } label: {
                        HStack(spacing: 3) {
                            Text(terminal)
                            Image(systemName: "arrow.up.forward")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.09)))
                    }
                    .buttonStyle(.plain)
                    .help("Jump to \(terminal)")
                }
            }
            .padding(.horizontal, 4)

            if agent.transcriptPath == nil {
                fallbackInfo
            } else {
                transcript
            }

            if let plan = agent.plan {
                PlanSection(markdown: plan)
            }

            if !agent.todos.isEmpty {
                TasksSection(todos: agent.todos)
            }

            if !agent.subagents.isEmpty {
                SubagentsSection(subagents: agent.subagents)
            }

            if agent.status == .working, let activity = agent.activity {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text(activity)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.40, green: 0.58, blue: 1.0))
                }
                .padding(.horizontal, 6)
            }

            if agent.terminalApp != nil {
                replyField
            }
        }
        .onAppear(perform: load)
        .onChange(of: agent) { _, _ in load() }
    }

    /// Quick-reply straight into the agent's terminal session.
    private var replyField: some View {
        HStack(spacing: 8) {
            TextField("Reply to \(agent.kind.displayName)…", text: $replyText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .onSubmit(sendReply)
            Button(action: sendReply) {
                Image(systemName: justSent ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(justSent ? AgentStatus.working.color
                        : replyText.isEmpty ? .white.opacity(0.3) : .white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .disabled(replyText.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    private func sendReply() {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let target = agent
        replyText = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = TerminalBridge.send(text: text, to: target)
            DispatchQueue.main.async {
                guard ok else { return }
                justSent = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { justSent = false }
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.isUser ? "You" : agent.kind.displayName)
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(message.isUser ? .white.opacity(0.4) : agent.kind.color)
                            Text(message.text)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.white.opacity(message.isUser ? 0.6 : 0.9))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(message.id)
                    }
                    if messages.isEmpty {
                        Text("No conversation yet")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 380)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.04)))
            .onChange(of: messages) { _, new in
                if let last = new.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onAppear {
                if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var fallbackInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            InfoRow(label: "Status", value: agent.status.label)
            InfoRow(label: "Directory", value: agent.cwd ?? "—")
            InfoRow(label: "PID", value: "\(agent.id)")
            InfoRow(label: "CPU", value: String(format: "%.1f%%", agent.cpu))
            InfoRow(label: "Uptime", value: agent.elapsed)
            Text("Output preview is available for Claude Code, Codex, and saved Gemini chats. \(agent.kind.displayName) support is coming.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white.opacity(0.04)))
    }

    private func load() {
        guard let path = agent.transcriptPath else { return }
        let kind = agent.kind
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded: [ChatMessage]
            switch kind {
            case .codex: loaded = CodexSessions.recentMessages(path: path)
            case .gemini: loaded = GeminiSessions.recentMessages(path: path)
            default: loaded = ClaudeSessions.recentMessages(path: path)
            }
            DispatchQueue.main.async {
                if loaded != messages { messages = loaded }
            }
        }
    }
}

private struct TasksSection: View {
    let todos: [Todo]
    var compact = false

    private var done: Int { todos.filter { $0.status == "completed" }.count }
    private var inProgress: Int { todos.filter { $0.status == "in_progress" }.count }
    private var open: Int { todos.count - done - inProgress }

    /// Active items first, then a couple of recent completions.
    private var visible: [Todo] {
        let active = todos.filter { $0.status != "completed" }
        let completed = todos.filter { $0.status == "completed" }
        return Array((active + completed).prefix(compact ? 4 : 6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Tasks")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                Text("(\(done) done, \(inProgress) in progress, \(open) open)")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }

            ForEach(Array(visible.enumerated()), id: \.offset) { _, todo in
                HStack(alignment: .top, spacing: 7) {
                    todoIcon(todo.status)
                        .padding(.top, 2)
                    Text(todo.content)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(todo.status == "completed" ? 0.35 : 0.85))
                        .strikethrough(todo.status == "completed", color: .white.opacity(0.35))
                        .lineLimit(1)
                }
            }

            if todos.count > visible.count {
                Text("… +\(todos.count - visible.count) more")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(compact ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous)
            .fill(.white.opacity(compact ? 0.05 : 0.04)))
    }

    @ViewBuilder
    private func todoIcon(_ status: String) -> some View {
        switch status {
        case "completed":
            Image(systemName: "checkmark.square.fill")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))
        case "in_progress":
            Circle()
                .fill(Color(red: 0.35, green: 0.55, blue: 1.0))
                .frame(width: 8, height: 8)
        default:
            Image(systemName: "square")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// Fan-out Task subagents: running ones with a pulsing dot, recent finishes dimmed.
private struct SubagentsSection: View {
    let subagents: [Subagent]
    var compact = false

    private var running: Int { subagents.filter { !$0.done }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Agents")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                Text("(\(running) running)")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }

            ForEach(Array(subagents.prefix(compact ? 3 : 6).enumerated()), id: \.offset) { _, sub in
                HStack(spacing: 7) {
                    if sub.done {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.3))
                    } else {
                        PulsingDot(color: AgentStatus.working.color)
                    }
                    Text(sub.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(sub.done ? 0.35 : 0.85))
                        .lineLimit(1)
                    if let type = sub.type {
                        Text(type)
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer(minLength: 0)
                    if sub.done {
                        Text("Done")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            }
        }
        .padding(compact ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous)
            .fill(.white.opacity(compact ? 0.05 : 0.04)))
    }
}

/// The plan Claude presented via ExitPlanMode, lightly Markdown-rendered.
private struct PlanSection: View {
    let markdown: String
    @State private var collapsed = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { collapsed.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "list.clipboard")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("Plan")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !collapsed {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(renderedLines.enumerated()), id: \.offset) { _, line in
                            line
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            } else {
                Text(firstLinePreview)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(0.04)))
    }

    private var firstLinePreview: String {
        markdown.split(separator: "\n").first(where: { !$0.isEmpty })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) } ?? ""
    }

    /// Line-based Markdown: headers bold, bullets indented, inline styles
    /// via AttributedString. Good enough for plan text.
    private var renderedLines: [Text] {
        markdown.split(separator: "\n", omittingEmptySubsequences: false).prefix(80).map { raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            func inline(_ s: String, size: CGFloat, weight: Font.Weight = .regular,
                        opacity: Double = 0.75) -> Text {
                let attributed = (try? AttributedString(
                    markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                    ?? AttributedString(s)
                return Text(attributed)
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(.white.opacity(opacity))
            }
            if trimmed.hasPrefix("### ") {
                return inline(String(trimmed.dropFirst(4)), size: 11, weight: .semibold, opacity: 0.9)
            } else if trimmed.hasPrefix("## ") {
                return inline(String(trimmed.dropFirst(3)), size: 11.5, weight: .bold, opacity: 0.92)
            } else if trimmed.hasPrefix("# ") {
                return inline(String(trimmed.dropFirst(2)), size: 12, weight: .bold, opacity: 0.95)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                return Text("  •  ").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
                    + inline(String(trimmed.dropFirst(2)), size: 10.5)
            } else {
                return inline(line, size: 10.5)
            }
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

// MARK: - Shared bits

struct PulsingDot: View {
    let color: Color
    var active: Bool = true
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: color.opacity(0.9), radius: pulsing && active ? 4 : 1)
            .opacity(active ? (pulsing ? 1 : 0.55) : 0.45)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}
