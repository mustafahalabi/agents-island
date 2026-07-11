import SwiftUI
import UserNotifications

@main
struct AgentsIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var monitor = AgentMonitor.shared

    var body: some Scene {
        MenuBarExtra {
            menuContent
        } label: {
            let working = monitor.agents.filter { $0.status == .working }.count
            if working > 0 {
                Text("✦ \(working)")
            } else {
                Image(systemName: "sparkles")
            }
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        if monitor.agents.isEmpty {
            Text("No agents running")
        } else {
            ForEach(monitor.agents) { agent in
                Button("\(statusMark(agent.status))  \(agent.displayTitle) — \(agent.status.label)") {
                    TerminalBridge.jump(to: agent)
                }
            }
        }
        Divider()
        Button("Refresh Now") { AgentMonitor.shared.scanNow() }
        Button("Settings…") { SettingsWindowController.shared.show() }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Agents Island") { NSApp.terminate(nil) }
    }

    private func statusMark(_ status: AgentStatus) -> String {
        switch status {
        case .working: return "🟢"
        case .waiting: return "🟡"
        case .idle: return "⚪️"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateIfAlreadyRunning()

        Pref.registerDefaults()
        NSApp.setActivationPolicy(.accessory)
        LoginItem.enableOnFirstLaunch()
        requestNotificationPermission()

        AgentMonitor.shared.start()
        SoundEngine.shared.start()
        ApprovalCenter.shared.start()
        UsageTracker.shared.start()
        RemoteMonitor.shared.start()
        HotKeyCenter.shared.update()
        panel = NotchPanel(monitor: AgentMonitor.shared)
        SwitcherState.shared.panel = panel
        panel?.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.panel?.repositionOnTargetScreen()
        }

        // Settings posts this when display selection / notch tuning changes.
        NotificationCenter.default.addObserver(
            forName: .repositionPanel, object: nil, queue: .main
        ) { [weak self] _ in
            self?.panel?.repositionOnTargetScreen()
        }

        NotificationCenter.default.addObserver(
            forName: .agentCompleted, object: nil, queue: .main
        ) { note in
            guard UserDefaults.standard.bool(forKey: Pref.notifyOnComplete),
                  let pid = note.object as? Int32,
                  let agent = AgentMonitor.shared.agents.first(where: { $0.id == pid })
            else { return }
            Self.postNotification(
                title: "\(agent.kind.displayName) finished",
                body: agent.displayTitle + " — waiting for you",
                id: agent.id
            )
        }

        NotificationCenter.default.addObserver(
            forName: .agentStarted, object: nil, queue: .main
        ) { note in
            guard UserDefaults.standard.bool(forKey: Pref.notifyOnStart),
                  let pid = note.object as? Int32,
                  let agent = AgentMonitor.shared.agents.first(where: { $0.id == pid })
            else { return }
            Self.postNotification(
                title: "\(agent.kind.displayName) session started",
                body: agent.displayTitle,
                id: agent.id
            )
        }
    }

    /// Only one island per Mac — old instances linger across rebuilds.
    private func terminateIfAlreadyRunning() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            others.forEach { $0.terminate() }
        }
    }

    private func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func postNotification(title: String, body: String, id: Int32) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: "agent-\(id)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
