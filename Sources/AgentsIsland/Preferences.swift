import Foundation

/// UserDefaults-backed preferences, shared between the Settings UI
/// (via @AppStorage) and the monitor/views (via these accessors).
enum Pref {
    // MARK: General — expansion
    static let expandOnHover = "expandOnHover"          // hover opens the panel
    static let hoverDuration = "hoverDuration"          // seconds of hover intent before opening
    static let smartSuppression = "smartSuppression"    // no auto-expand when the agent's terminal is frontmost
    static let autoRevealOnComplete = "autoRevealOnComplete" // expand island when an agent finishes

    // MARK: General — visibility
    static let hideInFullscreen = "hideInFullscreen"    // hide the island on fullscreen spaces
    static let autoHideWhenEmpty = "autoHideWhenEmpty"  // hide pill when no agents

    // MARK: General — dismissal
    static let autoCollapse = "autoCollapse"            // collapse when mouse leaves
    static let autoRevealDwell = "autoRevealDwell"      // seconds an auto-reveal stays open
    static let dismissRevealOnOutsideClick = "dismissRevealOnOutsideClick"
    static let hideIdleAfterMinutes = "hideIdleAfterMinutes" // 0 = never

    // MARK: General — interaction
    static let disableClickToJump = "disableClickToJump" // card click opens detail instead of the terminal
    static let pollInterval = "pollInterval"            // seconds

    // MARK: Display
    static let pillStyle = "pillStyle"                  // "clean" | "detailed"
    static let displaySelection = "displaySelection"    // "auto" | "id:<CGDirectDisplayID>"
    static let contentFontSize = "contentFontSize"      // base pt for card text
    static let maxPanelWidth = "maxPanelWidth"          // expanded panel width, pt
    static let maxPanelHeight = "maxPanelHeight"        // session list scroll height cap, pt
    static let showLastPrompt = "showLastPrompt"
    static let showActivity = "showActivity"
    static let showTerminalChip = "showTerminalChip"
    static let showTasks = "showTasks"                  // task checklist on session cards
    static let showModel = "showModel"                  // AI model chip on cards
    static let showGitBranch = "showGitBranch"          // git branch chip on cards
    static let showSubagents = "showSubagents"          // fan-out Task subagents on cards
    static let maxVisibleSessions = "maxVisibleSessions"
    static let notchWidthOffset = "notchWidthOffset"    // pt added to the detected notch width
    static let notchHeightOffset = "notchHeightOffset"  // pt added to the detected notch height

    // MARK: Sound
    static let soundsEnabled = "soundsEnabled"          // master switch
    static let soundVolume = "soundVolume"              // 0…1
    static let soundSessionStart = "soundSessionStart"  // sound name or "Off"
    static let soundTaskComplete = "soundTaskComplete"
    static let soundAcknowledge = "soundAcknowledge"    // you replied, agent got to work
    static let soundApprovalNeeded = "soundApprovalNeeded" // permission request pending
    static let quietHoursEnabled = "quietHoursEnabled"
    static let quietHoursStart = "quietHoursStart"      // minutes from midnight
    static let quietHoursEnd = "quietHoursEnd"

    // MARK: Usage
    static let usageEnabled = "usageEnabled"            // estimate quota from transcripts
    static let usagePlan = "usagePlan"                  // "pro" | "max5x" | "max20x"

    // MARK: Notifications
    static let notifyOnComplete = "notifyOnComplete"    // macOS notification when an agent finishes
    static let notifyOnStart = "notifyOnStart"          // macOS notification when a session appears

    // MARK: Shortcuts
    static let shortcutsEnabled = "shortcutsEnabled"
    static let shortcutModifier = "shortcutModifier"    // "control" | "option" | "command"
    static let reverseSwitcher = "reverseSwitcher"      // shift+modifier cycles backwards

    // MARK: SSH remotes
    static let sshHosts = "sshHosts"                    // JSON [{host, enabled}]

    // MARK: Agents
    static let disabledAgents = "disabledAgents"        // CSV of AgentKind rawValues

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            expandOnHover: true,
            hoverDuration: 0.15,
            smartSuppression: true,
            autoRevealOnComplete: true,

            hideInFullscreen: true,
            autoHideWhenEmpty: false,

            autoCollapse: true,
            autoRevealDwell: 5.0,
            dismissRevealOnOutsideClick: false,
            hideIdleAfterMinutes: 0,

            disableClickToJump: false,
            pollInterval: 2.0,

            pillStyle: "clean",
            displaySelection: "auto",
            contentFontSize: 11,
            maxPanelWidth: 530.0,
            maxPanelHeight: 560.0,
            showLastPrompt: true,
            showActivity: true,
            showTerminalChip: true,
            showTasks: true,
            showModel: true,
            showGitBranch: true,
            showSubagents: true,
            maxVisibleSessions: 6,
            notchWidthOffset: 0.0,
            notchHeightOffset: 0.0,

            soundsEnabled: true,
            soundVolume: 0.5,
            soundSessionStart: "Off",
            soundTaskComplete: "Glass",
            soundAcknowledge: "Off",
            soundApprovalNeeded: "Ping",
            quietHoursEnabled: false,
            quietHoursStart: 22 * 60,
            quietHoursEnd: 8 * 60,

            usageEnabled: true,
            usagePlan: "max5x",

            notifyOnComplete: true,
            notifyOnStart: false,

            shortcutsEnabled: true,
            shortcutModifier: "control",
            reverseSwitcher: true,

            disabledAgents: "",
        ])
    }

    static var disabledKinds: Set<AgentKind> {
        let csv = UserDefaults.standard.string(forKey: disabledAgents) ?? ""
        return Set(csv.split(separator: ",").compactMap { AgentKind(rawValue: String($0)) })
    }
}

extension Notification.Name {
    /// Posted with the pid as `object` when an agent finishes working.
    static let agentCompleted = Notification.Name("agentCompleted")
    /// Posted with the pid as `object` when a new agent session appears.
    static let agentStarted = Notification.Name("agentStarted")
    /// Posted with the pid as `object` when an agent goes waiting → working.
    static let agentAcknowledged = Notification.Name("agentAcknowledged")
    /// The panel should re-detect its screen / notch metrics.
    static let repositionPanel = Notification.Name("repositionPanel")
    /// Ask the island to expand (object: "switcher" enables keyboard mode UI).
    static let islandExpand = Notification.Name("islandExpand")
    /// Ask the island to collapse.
    static let islandCollapse = Notification.Name("islandCollapse")
}
