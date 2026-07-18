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

    /// Why the updater is unavailable, if it is — shown in About.
    @Published private(set) var unavailableReason: String?

    let channel = Install.channel

    private override init() {
        super.init()

        switch channel {
        case .homebrew:
            unavailableReason = "Installed with Homebrew — update with "
                + "`brew upgrade --cask agents-island` so the cask stays in sync."
            return
        case .unsigned:
            unavailableReason = "This build has no update key, so it can't verify "
                + "a download. Local builds update by rebuilding."
            return
        case .direct:
            break
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: driverDelegate
        )
        self.controller = controller

        canCheck = controller.updater.canCheckForUpdates
        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates, options: [.initial, .new]
        ) { [weak self] updater, _ in
            Task { @MainActor in self?.canCheck = updater.canCheckForUpdates }
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
        if state.userInitiated {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        // Nothing to tear down — the app stays .accessory throughout.
    }
}
