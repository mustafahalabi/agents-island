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
    @AppStorage(Pref.contentFontSize) private var fontSize = 11
    @State private var hovered = false

    private var fs: CGFloat { CGFloat(fontSize) }

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

                // Line 2: the user's last message
                if showLastPrompt, let prompt = agent.lastPrompt {
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
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.white.opacity(selected ? 0.11 : hovered ? 0.09 : agent.status == .working ? 0.06 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(
                    selected ? Color(red: 0.45, green: 0.62, blue: 1.0).opacity(0.8) : .white.opacity(0.06),
                    lineWidth: selected ? 1.5 : 1
                )
        )
        .onHover { inside in
            hovered = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
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

            if !agent.todos.isEmpty {
                TasksSection(todos: agent.todos)
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

        }
        .onAppear(perform: load)
        .onChange(of: agent) { _, _ in load() }
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
