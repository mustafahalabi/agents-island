import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Panes

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, integrations, notifications, display, sound, usage, agents, shortcuts, sshRemote = "ssh", about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .integrations: return "Integrations"
        case .notifications: return "Notifications"
        case .display: return "Display"
        case .sound: return "Sound"
        case .usage: return "Usage"
        case .agents: return "Agents"
        case .shortcuts: return "Shortcuts"
        case .sshRemote: return "SSH Remote"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .integrations: return "puzzlepiece.extension.fill"
        case .notifications: return "bell.badge.fill"
        case .display: return "textformat.size"
        case .sound: return "speaker.wave.2.fill"
        case .usage: return "gauge.with.needle.fill"
        case .agents: return "sparkles"
        case .shortcuts: return "keyboard.fill"
        case .sshRemote: return "globe"
        case .about: return "info.circle.fill"
        }
    }

    var tileColor: Color {
        switch self {
        case .general: return Color(white: 0.45)
        case .integrations: return Color(red: 0.30, green: 0.65, blue: 0.90)
        case .notifications: return Color(red: 0.94, green: 0.35, blue: 0.32)
        case .display: return Color(red: 0.45, green: 0.45, blue: 0.95)
        case .sound: return Color(red: 0.25, green: 0.75, blue: 0.40)
        case .usage: return Color(red: 0.90, green: 0.30, blue: 0.45)
        case .agents: return Color(red: 0.95, green: 0.60, blue: 0.20)
        case .shortcuts: return Color(red: 0.70, green: 0.40, blue: 0.90)
        case .sshRemote: return Color(red: 0.35, green: 0.75, blue: 0.75)
        case .about: return Color(red: 0.30, green: 0.60, blue: 0.95)
        }
    }

    /// Panes shown below the "Advanced" separator in the sidebar.
    static let main: [SettingsPane] = [.general, .integrations, .notifications, .display, .sound, .usage, .agents]
    static let advanced: [SettingsPane] = [.shortcuts, .sshRemote, .about]
}

struct SettingsView: View {
    @State private var pane: SettingsPane = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(width: 780, height: 640)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.main) { item in
                SidebarRow(pane: item, selected: pane == item) { pane = item }
            }
            Text("Advanced")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 14)
                .padding(.leading, 10)
                .padding(.bottom, 2)
            ForEach(SettingsPane.advanced) { item in
                SidebarRow(pane: item, selected: pane == item) { pane = item }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.top, 40) // clear the traffic lights (transparent titlebar)
        .frame(width: 200)
        .background(.black.opacity(0.15))
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(pane.tileColor.gradient)
                        .frame(width: 28, height: 28)
                        .overlay(
                            Image(systemName: pane.icon)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                    Text(pane.title)
                        .font(.system(size: 22, weight: .bold))
                }
                .padding(.bottom, 2)

                switch pane {
                case .general: GeneralPane()
                case .integrations: IntegrationsPane()
                case .notifications: NotificationsPane()
                case .display: DisplayPane()
                case .sound: SoundPane()
                case .usage: UsagePane()
                case .agents: AgentsPane()
                case .shortcuts: ShortcutsPane()
                case .sshRemote: SSHRemotePane()
                case .about: AboutPane()
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .padding(.top, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SidebarRow: View {
    let pane: SettingsPane
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(pane.tileColor.gradient)
                    .frame(width: 24, height: 24)
                    .overlay(
                        Image(systemName: pane.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                Text(pane.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.12) : hovered ? Color.white.opacity(0.05) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Building blocks

/// A grouped card of rows, like System Settings sections.
struct SSection<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) { content() }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                )
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One settings row: title (+ optional subtitle) with a trailing control.
struct SRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Divider between rows inside an SSection card.
struct SDiv: View {
    var body: some View {
        Divider().padding(.leading, 14)
    }
}

/// Small keycap badge, e.g. ⌃G or esc.
struct KeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
            )
    }
}

// MARK: - General

private struct GeneralPane: View {
    @AppStorage(Pref.expandOnHover) private var expandOnHover = true
    @AppStorage(Pref.hoverDuration) private var hoverDuration = 0.15
    @AppStorage(Pref.smartSuppression) private var smartSuppression = true
    @AppStorage(Pref.autoRevealOnComplete) private var autoRevealOnComplete = true
    @AppStorage(Pref.hideInFullscreen) private var hideInFullscreen = true
    @AppStorage(Pref.autoHideWhenEmpty) private var autoHideWhenEmpty = false
    @AppStorage(Pref.autoCollapse) private var autoCollapse = true
    @AppStorage(Pref.autoRevealDwell) private var autoRevealDwell = 5.0
    @AppStorage(Pref.dismissRevealOnOutsideClick) private var dismissOutsideClick = false
    @AppStorage(Pref.hideIdleAfterMinutes) private var hideIdleAfterMinutes = 0
    @AppStorage(Pref.disableClickToJump) private var disableClickToJump = false
    @AppStorage(Pref.pollInterval) private var pollInterval = 2.0
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SSection(title: "System") {
                SRow(title: "Launch at Login") {
                    Toggle("", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(!LoginItem.isAvailable)
                        .onChange(of: launchAtLogin) { _, new in LoginItem.set(enabled: new) }
                }
            }

            SSection(title: "Expansion") {
                SRow(title: "Expand notch on hover") {
                    Toggle("", isOn: $expandOnHover).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "Hover duration",
                     subtitle: "How long the cursor must rest on the island before it opens.") {
                    HStack(spacing: 10) {
                        Slider(value: $hoverDuration, in: 0...0.6, step: 0.05)
                            .frame(width: 160)
                        Text(String(format: "%.2fs", hoverDuration))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                .disabled(!expandOnHover)
                SDiv()
                SRow(title: "Smart suppression",
                     subtitle: "Don't auto-expand when the agent's terminal is already in focus.") {
                    Toggle("", isOn: $smartSuppression).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "Auto-expand panel on task complete",
                     subtitle: "Turn off to keep the panel collapsed on completion — the notch glow and sound still fire.") {
                    Toggle("", isOn: $autoRevealOnComplete).toggleStyle(.switch).labelsHidden()
                }
            }

            SSection(title: "Visibility") {
                SRow(title: "Hide in fullscreen",
                     subtitle: "Hides the island on fullscreen spaces. Keep off if your menu bar is set to auto-hide.") {
                    Toggle("", isOn: $hideInFullscreen).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "Auto-hide when no active sessions") {
                    Toggle("", isOn: $autoHideWhenEmpty).toggleStyle(.switch).labelsHidden()
                }
            }

            SSection(title: "Dismissal") {
                SRow(title: "Auto-collapse on mouse leave") {
                    Toggle("", isOn: $autoCollapse).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "Auto reveal dwell",
                     subtitle: "How long the panel stays open after a completion reveal.") {
                    Picker("", selection: $autoRevealDwell) {
                        ForEach([2.0, 3.0, 5.0, 8.0, 10.0, 15.0], id: \.self) {
                            Text("\(Int($0))s").tag($0)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SDiv()
                SRow(title: "Dismiss auto reveal on outside click",
                     subtitle: "Clicking anywhere outside the panel closes a completion reveal immediately.") {
                    Toggle("", isOn: $dismissOutsideClick).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "Idle session cleanup",
                     subtitle: "Hide Claude sessions with no activity for this long. They keep running.") {
                    Picker("", selection: $hideIdleAfterMinutes) {
                        Text("Never").tag(0)
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                        Text("2 hours").tag(120)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SSection(title: "Interaction") {
                SRow(title: "Disable click-to-jump",
                     subtitle: "When enabled, clicking a session opens its detail view instead of switching to its terminal.") {
                    Toggle("", isOn: $disableClickToJump).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "Refresh interval") {
                    Picker("", selection: $pollInterval) {
                        Text("1 second").tag(1.0)
                        Text("2 seconds").tag(2.0)
                        Text("3 seconds").tag(3.0)
                        Text("5 seconds").tag(5.0)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }
}

// MARK: - Integrations

private struct IntegrationsPane: View {
    @State private var installed = ApprovalCenter.hookInstalled

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SSection(title: "Claude Code",
                     footer: installed
                     ? "When Claude asks for permission, the island pops up with Approve / Always Allow / Deny — the buttons answer the terminal prompt for you (1 / 2 / 3). Global shortcuts activate too while a request is pending."
                     : "Installs a Notification hook into ~/.claude/settings.json (a backup is written first). The hook never blocks Claude — it just tells the island when permission is needed. Restart running Claude sessions to pick it up.") {
                SRow(title: "Permission approvals from the island",
                     subtitle: installed ? "Hook installed" : "Hook not installed") {
                    Button(installed ? "Remove" : "Install") {
                        if installed {
                            ApprovalCenter.uninstallHook()
                        } else {
                            ApprovalCenter.installHook()
                        }
                        installed = ApprovalCenter.hookInstalled
                    }
                }
            }

            SSection(title: "Terminal control", footer: "Approvals in iTerm and tmux are answered precisely via the session's tty. Terminal.app and other terminals are activated first and the key is synthesized — macOS will ask once for Accessibility permission.") {
                SRow(title: "iTerm / tmux", subtitle: "Exact tty targeting, no extra permissions") { EmptyView() }
                SDiv()
                SRow(title: "Terminal.app & others", subtitle: "System Events keystroke (Accessibility)") { EmptyView() }
            }
        }
    }
}

// MARK: - Notifications

private struct NotificationsPane: View {
    @AppStorage(Pref.notifyOnComplete) private var notifyOnComplete = true
    @AppStorage(Pref.notifyOnStart) private var notifyOnStart = false

    var body: some View {
        SSection(title: "macOS Notifications", footer: "Notifications need permission the first time — grant it in System Settings → Notifications if nothing shows up.") {
            SRow(title: "Agent finished",
                 subtitle: "\u{201C}Claude finished — fix auth bug — waiting for you\u{201D}") {
                Toggle("", isOn: $notifyOnComplete).toggleStyle(.switch).labelsHidden()
            }
            SDiv()
            SRow(title: "New session started") {
                Toggle("", isOn: $notifyOnStart).toggleStyle(.switch).labelsHidden()
            }
        }
    }
}

// MARK: - Display

private struct DisplayPane: View {
    @AppStorage(Pref.pillStyle) private var pillStyle = "clean"
    @AppStorage(Pref.displaySelection) private var displaySelection = "auto"
    @AppStorage(Pref.contentFontSize) private var contentFontSize = 11
    @AppStorage(Pref.maxPanelWidth) private var maxPanelWidth = 530.0
    @AppStorage(Pref.maxPanelHeight) private var maxPanelHeight = 560.0
    @AppStorage(Pref.showLastPrompt) private var showLastPrompt = true
    @AppStorage(Pref.showActivity) private var showActivity = true
    @AppStorage(Pref.showTerminalChip) private var showTerminalChip = true
    @AppStorage(Pref.showTasks) private var showTasks = true
    @AppStorage(Pref.showModel) private var showModel = true
    @AppStorage(Pref.showGitBranch) private var showGitBranch = true
    @AppStorage(Pref.showSubagents) private var showSubagents = true
    @AppStorage(Pref.maxVisibleSessions) private var maxVisibleSessions = 6
    @AppStorage(Pref.notchWidthOffset) private var notchWidthOffset = 0.0
    @AppStorage(Pref.notchHeightOffset) private var notchHeightOffset = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SSection(title: "Notch") {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        PillStyleCard(
                            name: "Clean", caption: "More space for the menu bar",
                            style: "clean", selection: $pillStyle
                        )
                        PillStyleCard(
                            name: "Detailed", caption: "Live activity & session count",
                            style: "detailed", selection: $pillStyle
                        )
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)

                    Divider().padding(.leading, 14)

                    SRow(title: "Display",
                         subtitle: "Which screen the island lives on. Automatic prefers the built-in notched display.") {
                        DisplayPicker(selection: $displaySelection)
                    }
                }
                .padding(.bottom, 2)
            }

            SSection(title: "Panel size") {
                SRow(title: "Content Font Size") {
                    Picker("", selection: $contentFontSize) {
                        Text("10pt").tag(10)
                        Text("11pt (Default)").tag(11)
                        Text("12pt").tag(12)
                        Text("13pt").tag(13)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SDiv()
                SRow(title: "Max Panel Width") {
                    SliderWithValue(value: $maxPanelWidth, range: 460...800, step: 10, unit: "pt")
                }
                SDiv()
                SRow(title: "Max Panel Height",
                     subtitle: "The session list scrolls when it grows past this.") {
                    SliderWithValue(value: $maxPanelHeight, range: 320...800, step: 20, unit: "pt")
                }
            }

            SSection(title: "Session card") {
                SRow(title: "Show last message") {
                    Toggle("", isOn: $showLastPrompt).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "Show live activity",
                     subtitle: "e.g. \u{201C}Writing IslandView.swift\u{201D} while the agent works.") {
                    Toggle("", isOn: $showActivity).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "Show AI model", subtitle: "Opus, Sonnet, Fable… read from the session transcript.") {
                    Toggle("", isOn: $showModel).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "Show git branch") {
                    Toggle("", isOn: $showGitBranch).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "Show subagents",
                     subtitle: "Fan-out Task subagents while they run. Keeps the panel clean when off.") {
                    Toggle("", isOn: $showSubagents).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "Show terminal app chip") {
                    Toggle("", isOn: $showTerminalChip).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "Show task checklists") {
                    Toggle("", isOn: $showTasks).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "Max visible sessions") {
                    Stepper("\(maxVisibleSessions)", value: $maxVisibleSessions, in: 3...12)
                        .fixedSize()
                }
            }

            SSection(title: "Tuning",
                     footer: "Fine-tune the pill dimensions if your machine doesn't fit perfectly. 0 uses the macOS API value.") {
                SRow(title: "Notch width") {
                    SliderWithValue(value: $notchWidthOffset, range: -60...60, step: 2, unit: "pt", signed: true)
                }
                SDiv()
                SRow(title: "Notch height") {
                    SliderWithValue(value: $notchHeightOffset, range: -10...20, step: 1, unit: "pt", signed: true)
                }
            }
        }
        .onChange(of: displaySelection) { _, _ in reposition() }
        .onChange(of: notchWidthOffset) { _, _ in reposition() }
        .onChange(of: notchHeightOffset) { _, _ in reposition() }
    }

    private func reposition() {
        NotificationCenter.default.post(name: .repositionPanel, object: nil)
    }
}

/// Selectable mini-preview card for the collapsed pill style.
private struct PillStyleCard: View {
    let name: String
    let caption: String
    let style: String
    @Binding var selection: String

    private var selected: Bool { selection == style }

    var body: some View {
        Button { selection = style } label: {
            VStack(spacing: 8) {
                // Mini pill mock
                HStack(spacing: 5) {
                    Circle().fill(AgentStatus.working.color).frame(width: 5, height: 5)
                    if style == "detailed" {
                        Capsule().fill(.white.opacity(0.35)).frame(width: 42, height: 4)
                        Spacer(minLength: 4)
                        Text("2 ses")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                    } else {
                        Spacer(minLength: 4)
                        Text("2")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(.horizontal, 9)
                .frame(width: style == "detailed" ? 110 : 76, height: 20)
                .background(Capsule().fill(.black))
                .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))

                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                Text(caption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.08 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.1),
                                  lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Picker over connected screens; stores "auto" or "id:<CGDirectDisplayID>".
private struct DisplayPicker: View {
    @Binding var selection: String
    @State private var screens: [(id: String, name: String)] = []

    var body: some View {
        Picker("", selection: $selection) {
            Text("Automatic").tag("auto")
            ForEach(screens, id: \.id) { screen in
                Text(screen.name).tag(screen.id)
            }
            // Keep a stale selection visible instead of crashing the picker.
            if selection != "auto", !screens.contains(where: { $0.id == selection }) {
                Text("Disconnected display").tag(selection)
            }
        }
        .labelsHidden()
        .fixedSize()
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification)) { _ in refresh() }
    }

    private func refresh() {
        screens = NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            let notchMark = screen.safeAreaInsets.top > 0 ? " (notch)" : ""
            return ("id:\(id)", screen.localizedName + notchMark)
        }
    }
}

private struct SliderWithValue: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    var signed = false

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range, step: step)
                .frame(width: 170)
            Text("\(signed && value > 0 ? "+" : "")\(Int(value))\(unit)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}

// MARK: - Sound

private struct SoundPane: View {
    @AppStorage(Pref.soundsEnabled) private var soundsEnabled = true
    @AppStorage(Pref.soundVolume) private var volume = 0.5
    @AppStorage(Pref.quietHoursEnabled) private var quietEnabled = false
    @AppStorage(Pref.quietHoursStart) private var quietStart = 22 * 60
    @AppStorage(Pref.quietHoursEnd) private var quietEnd = 8 * 60
    @State private var customSounds: [String] = SoundEngine.customSoundNames()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SSection {
                SRow(title: "Enable Sound Effects") {
                    Toggle("", isOn: $soundsEnabled).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "Volume") {
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.fill")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Slider(value: $volume, in: 0...1) { editing in
                            if !editing { SoundEngine.shared.preview(currentPreviewSound) }
                        }
                        .frame(width: 150)
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("\(Int(volume * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                .disabled(!soundsEnabled)
            }

            SSection(title: "Session") {
                SoundPickerRow(title: "Session Start",
                               subtitle: "A new Claude / Codex / Gemini session appears",
                               key: Pref.soundSessionStart, defaultSound: SoundEngine.off, customSounds: customSounds)
                SDiv()
                SoundPickerRow(title: "Task Complete",
                               subtitle: "AI finished its turn",
                               key: Pref.soundTaskComplete, defaultSound: "Glass", customSounds: customSounds)
                SDiv()
                SoundPickerRow(title: "Task Acknowledge",
                               subtitle: "You submitted a prompt and the agent got to work",
                               key: Pref.soundAcknowledge, defaultSound: SoundEngine.off, customSounds: customSounds)
            }

            SSection(title: "Interactions") {
                SoundPickerRow(title: "Approval Needed",
                               subtitle: "Claude asks for permission (needs the hook — see Integrations)",
                               key: Pref.soundApprovalNeeded, defaultSound: "Ping", customSounds: customSounds)
            }

            SSection(title: "My Sounds", footer: "Imported sounds appear in every picker above.") {
                if customSounds.isEmpty {
                    SRow(title: "No imported sounds yet.") { EmptyView() }
                }
                ForEach(customSounds, id: \.self) { name in
                    SRow(title: name) {
                        HStack(spacing: 10) {
                            Button {
                                SoundEngine.shared.preview(SoundEngine.customPrefix + name)
                            } label: {
                                Image(systemName: "play.circle.fill").font(.system(size: 16))
                            }
                            .buttonStyle(.plain)
                            Button {
                                SoundEngine.removeSound(named: name)
                                customSounds = SoundEngine.customSoundNames()
                            } label: {
                                Image(systemName: "trash").font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    SDiv()
                }
                SRow(title: "") {
                    Button(action: importSound) {
                        Label("Add Sound…", systemImage: "plus")
                    }
                }
            }

            SSection(title: "Quiet Hours",
                     footer: "Mutes all sounds during the selected time range (crosses midnight if end is earlier than start). Useful when agents run overnight.") {
                SRow(title: "Silence during quiet hours") {
                    Toggle("", isOn: $quietEnabled).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "From") { HourPicker(minutes: $quietStart) }
                    .disabled(!quietEnabled)
                SDiv()
                SRow(title: "Until") { HourPicker(minutes: $quietEnd) }
                    .disabled(!quietEnabled)
            }
        }
    }

    private var currentPreviewSound: String {
        let configured = UserDefaults.standard.string(forKey: Pref.soundTaskComplete) ?? "Glass"
        return configured == SoundEngine.off ? "Glass" : configured
    }

    private func importSound() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { SoundEngine.importSound(from: url) }
        customSounds = SoundEngine.customSoundNames()
    }
}

/// Sound selector + preview button for one event.
private struct SoundPickerRow: View {
    let title: String
    let subtitle: String?
    let key: String
    let customSounds: [String]
    @AppStorage private var selection: String

    init(title: String, subtitle: String? = nil, key: String, defaultSound: String, customSounds: [String]) {
        self.title = title
        self.subtitle = subtitle
        self.key = key
        self.customSounds = customSounds
        // Match Pref.registerDefaults so the picker's default and the value
        // SoundEngine reads never disagree.
        _selection = AppStorage(wrappedValue: defaultSound, key)
    }

    var body: some View {
        SRow(title: title, subtitle: subtitle) {
            HStack(spacing: 8) {
                Picker("", selection: $selection) {
                    Text("Off").tag(SoundEngine.off)
                    ForEach(customSounds, id: \.self) { name in
                        Text("♪ \(name)").tag(SoundEngine.customPrefix + name)
                    }
                    ForEach(SoundEngine.systemSounds, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                .onChange(of: selection) { _, new in
                    SoundEngine.shared.preview(new)
                }

                Button {
                    SoundEngine.shared.preview(selection)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(selection == SoundEngine.off ? .secondary : .primary)
                }
                .buttonStyle(.plain)
                .disabled(selection == SoundEngine.off)
            }
        }
    }
}

private struct HourPicker: View {
    @Binding var minutes: Int

    var body: some View {
        Picker("", selection: $minutes) {
            ForEach(0..<48, id: \.self) { slot in
                Text(label(slot * 30)).tag(slot * 30)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func label(_ mins: Int) -> String {
        String(format: "%02d:%02d", mins / 60, mins % 60)
    }
}

// MARK: - Usage

private struct UsagePane: View {
    @AppStorage(Pref.usageEnabled) private var enabled = true
    @AppStorage(Pref.usagePlan) private var plan = "max5x"
    @ObservedObject private var tracker = UsageTracker.shared

    var body: some View {
        let budgets = UsageTracker.budgets(plan: plan)
        let snapshot = tracker.snapshot
        VStack(alignment: .leading, spacing: 22) {
            SSection(footer: "Estimated locally from transcript token counts (cache reads weighted at 10%). Anthropic doesn't publish exact budgets — pick the plan that matches yours and treat the percentages as a guide.") {
                SRow(title: "Show usage in the panel header") {
                    Toggle("", isOn: $enabled).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "Plan") {
                    Picker("", selection: $plan) {
                        Text("Pro").tag("pro")
                        Text("Max 5x").tag("max5x")
                        Text("Max 20x").tag("max20x")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            if enabled {
            SSection(title: "Current 5-hour window") {
                if let reset = snapshot.blockResetAt,
                   let percent = snapshot.blockPercent(budget: budgets.block) {
                    SRow(title: "Used", subtitle: Self.tokens(snapshot.blockTokens) + " weighted tokens") {
                        UsageBar(percent: percent)
                    }
                    SDiv()
                    SRow(title: "Resets") {
                        Text(reset, style: .relative)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    SRow(title: "No active session window",
                         subtitle: "A window opens with your next Claude message.") { EmptyView() }
                }
            }

            SSection(title: "Rolling 7 days") {
                SRow(title: "Used", subtitle: Self.tokens(snapshot.weekTokens) + " weighted tokens") {
                    UsageBar(percent: snapshot.weekPercent(budget: budgets.week))
                }
            }

            if tracker.codex.hasData {
                SSection(title: "Codex" + (tracker.codex.planType.map { " · \($0.capitalized)" } ?? ""),
                         footer: "Read straight from Codex's own rate-limit reports in ~/.codex — these are exact, not estimated.") {
                    if let primary = tracker.codex.primary { codexRow(primary) }
                    if let secondary = tracker.codex.secondary {
                        SDiv(); codexRow(secondary)
                    }
                }
            }
            }
        }
    }

    private func codexRow(_ window: UsageTracker.CodexWindow) -> some View {
        SRow(title: Self.windowTitle(window),
             subtitle: window.resetsAt.map { "Resets " + Self.relative($0) }) {
            UsageBar(percent: Int(window.usedPercent.rounded()))
        }
    }

    private static func windowTitle(_ window: UsageTracker.CodexWindow) -> String {
        let m = window.windowMinutes
        if m % 1440 == 0 { return "Rolling \(m / 1440)-day window" }
        if m % 60 == 0 { return "Current \(m / 60)-hour window" }
        return "\(m)-minute window"
    }

    private static let relFormatter = RelativeDateTimeFormatter()
    private static func relative(_ date: Date) -> String {
        relFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static func tokens(_ value: Double) -> String {
        value >= 1_000_000_000 ? String(format: "%.1fB", value / 1_000_000_000)
            : value >= 1_000_000 ? String(format: "%.1fM", value / 1_000_000)
            : String(format: "%.0fK", value / 1_000)
    }
}

private struct UsageBar: View {
    let percent: Int

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(percent >= 90 ? Color(red: 1.0, green: 0.45, blue: 0.45)
                            : percent >= 70 ? AgentStatus.waiting.color
                            : AgentStatus.working.color)
                        .frame(width: geo.size.width * min(1, CGFloat(percent) / 100))
                }
            }
            .frame(width: 120, height: 6)
            Text("\(min(percent, 999))%")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

// MARK: - Agents

private struct AgentsPane: View {
    @AppStorage(Pref.disabledAgents) private var disabledCSV = ""

    var body: some View {
        SSection(title: "Tracked agents",
                 footer: "Disabled agents are ignored entirely — they won't appear in the island or count toward the badge.") {
            ForEach(Array(AgentKind.allCases.enumerated()), id: \.element.rawValue) { index, kind in
                if index > 0 { SDiv() }
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(kind.color.gradient)
                        Image(systemName: kind.symbol)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 20, height: 20)
                    Text(kind.displayName)
                        .font(.system(size: 13))
                    Spacer()
                    Toggle("", isOn: binding(for: kind)).toggleStyle(.switch).labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
        }
    }

    private func binding(for kind: AgentKind) -> Binding<Bool> {
        Binding(
            get: { !disabledSet.contains(kind.rawValue) },
            set: { enabled in
                var set = disabledSet
                if enabled { set.remove(kind.rawValue) } else { set.insert(kind.rawValue) }
                disabledCSV = set.sorted().joined(separator: ",")
                AgentMonitor.shared.scanNow()
            }
        )
    }

    private var disabledSet: Set<String> {
        Set(disabledCSV.split(separator: ",").map(String.init))
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @AppStorage(Pref.shortcutsEnabled) private var enabled = true
    @AppStorage(Pref.shortcutModifier) private var modifier = "control"
    @AppStorage(Pref.reverseSwitcher) private var reverse = true

    private var mod: String { HotKeyCenter.modifierSymbol(modifier) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SSection(title: "Modifier Key") {
                SRow(title: "Modifier Key") {
                    Picker("", selection: $modifier) {
                        Text("⌃ Control").tag("control")
                        Text("⌥ Option").tag("option")
                        Text("⌘ Command").tag("command")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SSection(title: "Global Shortcuts") {
                SRow(title: "Enable Keyboard Shortcuts",
                     subtitle: "Turn off every Agents Island shortcut without clearing your mappings.") {
                    Toggle("", isOn: $enabled).toggleStyle(.switch).labelsHidden()
                }
                SDiv()
                SRow(title: "Open Switcher",
                     subtitle: "Tap to open, press again to cycle through sessions, ⏎ to jump (⌘Tab style).") {
                    KeyCap(label: "\(mod)G")
                }
                SDiv()
                SRow(title: "Reverse Switcher",
                     subtitle: "Adds Shift for backwards cycling. Only registered while enabled.") {
                    HStack(spacing: 10) {
                        KeyCap(label: "\(mod)⇧G")
                        Toggle("", isOn: $reverse).toggleStyle(.switch).labelsHidden()
                    }
                }
                SDiv()
                SRow(title: "Collapse Panel",
                     subtitle: "Active only while the switcher panel is open.") {
                    KeyCap(label: "esc")
                }
            }

            SSection(title: "Panel Shortcuts", footer: "Navigation is active while the switcher is open.") {
                SRow(title: "Navigate Sessions") {
                    HStack(spacing: 4) {
                        KeyCap(label: "↑")
                        KeyCap(label: "↓")
                    }
                }
                SDiv()
                SRow(title: "Jump to Terminal") {
                    HStack(spacing: 4) {
                        KeyCap(label: "⏎")
                        Text("or").font(.system(size: 11)).foregroundStyle(.secondary)
                        KeyCap(label: "T")
                    }
                }
            }

            SSection(title: "Approval Shortcuts",
                     footer: "Global, but only registered while a permission request is pending — they never shadow other apps' shortcuts in normal use. Needs the Claude Code hook (Integrations).") {
                SRow(title: "Approve") { KeyCap(label: "\(mod)Y") }
                SDiv()
                SRow(title: "Always Allow") { KeyCap(label: "\(mod)A") }
                SDiv()
                SRow(title: "Deny") { KeyCap(label: "\(mod)N") }
            }
        }
        .onChange(of: enabled) { _, _ in HotKeyCenter.shared.update() }
        .onChange(of: modifier) { _, _ in HotKeyCenter.shared.update() }
        .onChange(of: reverse) { _, _ in HotKeyCenter.shared.update() }
    }
}

// MARK: - SSH Remote

private struct SSHRemotePane: View {
    @State private var hosts = RemoteMonitor.hosts()
    @State private var newHost = ""
    @ObservedObject private var remote = RemoteMonitor.shared
    @State private var configHosts = RemoteMonitor.sshConfigHosts()

    /// ~/.ssh/config hosts not already added.
    private var unusedConfigHosts: [String] {
        let added = Set(hosts.map(\.host))
        return configHosts.filter { !added.contains($0) }
    }

    /// Enabled hosts we've confirmed a live SSH connection to.
    private var connectedHosts: [RemoteMonitor.Host] {
        hosts.filter { $0.enabled && remote.status[$0.host]?.reachability == .connected }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SSection(title: "Connected devices",
                     footer: "Machines reachable right now over key-based SSH. The count is the number of agent jobs currently running there — they also appear in the island with a host chip.") {
                if connectedHosts.isEmpty {
                    SRow(title: "No devices connected",
                         subtitle: hosts.isEmpty ? "Add a host below to start scanning."
                                                 : "Nothing reachable yet — check the host list below.") { EmptyView() }
                } else {
                    ForEach(Array(connectedHosts.enumerated()), id: \.element.host) { index, host in
                        if index > 0 { SDiv() }
                        let count = remote.status[host.host]?.sessionCount ?? 0
                        SRow(title: host.host,
                             subtitle: count == 0 ? "Connected · no agents running"
                                                  : "\(count) remote \(count == 1 ? "job" : "jobs") running") {
                            HStack(spacing: 8) {
                                Circle().fill(AgentStatus.working.color).frame(width: 8, height: 8)
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(AgentStatus.working.color)
                            }
                        }
                    }
                }
            }

            SSection(title: "Remote hosts",
                     footer: "Hosts are scanned every 10 seconds over ssh with BatchMode (key authentication only — set up your ~/.ssh/config first; nothing will ever prompt for a password). Remote sessions appear with a host chip; status is CPU-based, working directories come from /proc on Linux.") {
                if hosts.isEmpty {
                    SRow(title: "No remote hosts yet.") { EmptyView() }
                }
                ForEach(hosts) { host in
                    SRow(title: host.host) {
                        HStack(spacing: 12) {
                            statusBadge(host)
                            Button("Test") { RemoteMonitor.shared.testConnection(host: host.host) }
                                .controlSize(.small)
                                .disabled(!host.enabled)
                            Toggle("", isOn: binding(for: host)).toggleStyle(.switch).labelsHidden()
                            Button {
                                hosts.removeAll { $0.host == host.host }
                                RemoteMonitor.saveHosts(hosts)
                                hosts = RemoteMonitor.hosts()
                            } label: {
                                Image(systemName: "trash").font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    SDiv()
                }
                SRow(title: "") {
                    HStack(spacing: 8) {
                        TextField("user@server or ssh alias", text: $newHost)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onSubmit { add(newHost) }
                        Button("Add") { add(newHost) }
                            .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }

            if !unusedConfigHosts.isEmpty {
                SSection(title: "From ~/.ssh/config",
                         footer: "Hosts declared in your SSH config. Tap to add one — it uses the same key auth and connection settings you've already configured.") {
                    ForEach(Array(unusedConfigHosts.enumerated()), id: \.element) { index, alias in
                        if index > 0 { SDiv() }
                        SRow(title: alias) {
                            Button {
                                add(alias)
                            } label: {
                                Label("Add", systemImage: "plus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
        .onAppear { configHosts = RemoteMonitor.sshConfigHosts() }
    }

    @ViewBuilder
    private func statusBadge(_ host: RemoteMonitor.Host) -> some View {
        let (color, text): (Color, String) = {
            guard host.enabled else { return (Color(white: 0.5), "Disabled") }
            switch remote.status[host.host]?.reachability {
            case .connected: return (AgentStatus.working.color, "Connected")
            case .unreachable: return (Color(red: 1.0, green: 0.45, blue: 0.45), "Unreachable")
            case .checking: return (AgentStatus.waiting.color, "Checking…")
            case .unknown, .none: return (Color(white: 0.5), "Waiting…")
            }
        }()
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .help(remote.status[host.host]?.reachability == .unreachable
              ? "Could not connect. Ensure key-based SSH works: `ssh \(host.host)` should log in without a password."
              : "")
    }

    private func add(_ raw: String) {
        let trimmed = RemoteMonitor.normalize(raw)
        guard !trimmed.isEmpty, !hosts.contains(where: { $0.host == trimmed }) else { return }
        hosts.append(RemoteMonitor.Host(host: trimmed, enabled: true))
        newHost = ""
        RemoteMonitor.saveHosts(hosts)
        hosts = RemoteMonitor.hosts()
    }

    private func binding(for host: RemoteMonitor.Host) -> Binding<Bool> {
        Binding(
            get: { hosts.first { $0.host == host.host }?.enabled ?? false },
            set: { enabled in
                if let index = hosts.firstIndex(where: { $0.host == host.host }) {
                    hosts[index].enabled = enabled
                    RemoteMonitor.saveHosts(hosts)
                    hosts = RemoteMonitor.hosts()
                }
            }
        )
    }
}

// MARK: - About

private struct AboutPane: View {
    private var inApplications: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    /// The real bundle version, so the About pane never lies about the build.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SSection {
                VStack(spacing: 10) {
                    PixelBotView(status: .working, size: 42)
                    Text("Agents Island")
                        .font(.system(size: 18, weight: .bold))
                    Text("A Dynamic Island for your AI coding agents.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Version \(Self.appVersion)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("\(AgentKind.allCases.count) agents tracked")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            }

            SSection(title: "Installation",
                     footer: inApplications
                     ? "Running from /Applications."
                     : "Copies the app to /Applications and relaunches from there. Login item and permissions follow the stable bundle ID. Note: rebuilding with make-app.sh launches the dist copy again — pass --install to update /Applications.") {
                SRow(title: inApplications ? "Installed in /Applications" : "Install to /Applications",
                     subtitle: Bundle.main.bundlePath) {
                    if !inApplications {
                        Button("Install") { LoginItem.installToApplications() }
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(AgentStatus.working.color)
                    }
                }
            }

            SSection(title: "Tracked data", footer: "Everything is read locally — Claude's session registry, transcripts and task store under ~/.claude, Codex's rate limits under ~/.codex, plus the process table. Nothing leaves your Mac.") {
                SRow(title: "Claude Code sessions", subtitle: "~/.claude/sessions · projects · tasks") { EmptyView() }
                SDiv()
                SRow(title: "Codex usage", subtitle: "~/.codex rollout rate limits (exact)") { EmptyView() }
                SDiv()
                SRow(title: "Other agents", subtitle: "Process table scan (ps / lsof)") { EmptyView() }
            }
        }
    }
}
