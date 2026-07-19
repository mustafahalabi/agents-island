import AppKit
import Sparkle
import SwiftUI

/// In-app updates, backed by Sparkle.
///
/// Two things make this less standard than a normal Sparkle integration:
///
/// 1. **Homebrew.** The cask is a first-class install channel. If the app
///    replaced itself underneath Homebrew, the Caskroom manifest would go
///    stale and the next `brew upgrade` would fight the self-installed copy.
///    So a brew-managed bundle never self-updates — it points at
///    `brew upgrade --cask` instead. See `Install.channel`.
///
/// 2. **`LSUIElement`.** With no dock icon the app is `.accessory`, and an
///    accessory app's windows do not come forward on their own. Sparkle's
///    update window has to be handed activation explicitly, otherwise the
///    update appears to do nothing. See `UpdateDriverDelegate`.
///
/// The updater is also the app's only outbound network connection. It talks to
/// GitHub to fetch the appcast and the release; nothing about your agents,
/// sessions, or transcripts is ever sent anywhere.
@MainActor
final class UpdateController: NSObject, ObservableObject {
    static let shared = UpdateController()

    /// Nil when updates can't run at all — no public key baked in, or the
    /// bundle is managed by Homebrew.
    private var controller: SPUStandardUpdaterController?
    private let driverDelegate = UpdateDriverDelegate()

    /// Mirrors `updater.canCheckForUpdates` for the Settings button.
    @Published private(set) var canCheck = false
    private var canCheckObservation: NSKeyValueObservation?

    /// Shell command a Homebrew user runs instead of self-updating.
    static let brewUpgradeCommand = "brew upgrade --cask \(Install.caskToken)"

    let channel = Install.channel

    private override init() {
        super.init()

        // Both non-direct channels are deliberate, not faults: a Homebrew
        // install defers to brew so the cask cannot drift, and a keyless build
        // refuses to trust a download it cannot verify. The UI wording should
        // say which of those it is rather than implying something is broken.
        guard channel == .direct else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: driverDelegate
        )
        self.controller = controller

        canCheck = controller.updater.canCheckForUpdates
        // KVO fires off the main actor, and `canCheckForUpdates` is main-actor
        // isolated, so the value can't be read here in the callback. Hop first,
        // then read — and let the Task hold its own weak reference rather than
        // reaching back through the closure's capture.
        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates, options: [.initial, .new]
        ) { _, _ in
            Task { @MainActor [weak self] in
                guard let self, let controller = self.controller else { return }
                self.canCheck = controller.updater.canCheckForUpdates
            }
        }
    }

    /// User asked for a check — always shows UI, even when up to date.
    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    /// Background checks, mirrored into `Pref.autoCheckUpdates`.
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheckDate: Date? { controller?.updater.lastUpdateCheckDate }
}

// MARK: - Accessory-app activation

/// Sparkle shows its own windows, but an `.accessory` app never gets brought
/// to the front, so without this the update dialog opens behind everything and
/// the app looks broken. Activation is restored implicitly once the user
/// dismisses the window — the policy itself is never changed, since flipping to
/// `.regular` would pop a dock icon mid-update.
private final class UpdateDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // Only steal focus for checks the user actually asked for. A scheduled
        // check that found something waits for them to come to it.
        guard state.userInitiated else { return }
        // Sparkle calls this from a nonisolated context; NSApp is main-actor.
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        // Nothing to tear down — the app stays .accessory throughout.
    }
}
