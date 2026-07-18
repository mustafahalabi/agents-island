import Foundation

/// How this copy of the app was installed, which decides whether it is allowed
/// to update itself.
///
/// Deliberately free of any Sparkle import: this is the gate that keeps the
/// updater away from Homebrew-managed bundles, so it is compiled directly into
/// the logic tests (see scripts/tests/InstallChannelTests.swift).
enum Install {
    enum Channel: Equatable {
        case direct      // .dmg / .zip download — self-update is ours to do
        case homebrew    // cask-managed — defer to `brew upgrade`
        case unsigned    // no SUPublicEDKey (local build, CI) — can't verify
    }

    static let caskToken = "agents-island"

    /// Homebrew prefixes, Apple Silicon first.
    static let brewPrefixes = ["/opt/homebrew", "/usr/local"]

    /// make-app.sh writes this literal when no signing key is configured.
    static let unsetKey = "UNSET"

    /// How the running app was installed.
    static var channel: Channel {
        resolve(
            bundlePath: URL(fileURLWithPath: Bundle.main.bundlePath)
                .resolvingSymlinksInPath().path,
            publicKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            caskroomExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    /// Where Homebrew's `app` stanza puts the bundle.
    static let brewInstallPath = "/Applications/AgentsIsland.app"

    /// Pure decision, split out so it can be tested without a real install.
    ///
    /// Homebrew's `app` stanza *moves* the bundle into /Applications rather
    /// than symlinking it, so the bundle path alone doesn't reveal who owns it
    /// — what does is the Caskroom directory brew keeps for the token. `brew`
    /// itself is never shelled out to: it's slow, and it isn't on PATH inside a
    /// GUI app anyway.
    ///
    /// A Caskroom entry on its own is *not* enough. Maintainers running a local
    /// build out of `dist/` usually also have the cask installed, and treating
    /// that build as brew-managed would silently disable its updater — which is
    /// exactly the path we most need to be able to exercise. So the bundle has
    /// to actually be the copy brew manages.
    ///
    /// Homebrew is checked *before* the key, because a brew-managed install
    /// must never self-update even though it does carry a valid public key.
    static func resolve(
        bundlePath: String,
        publicKey: String?,
        caskroomExists: (String) -> Bool
    ) -> Channel {
        // Older casks symlinked into /Applications; the caller resolves
        // symlinks, so such a bundle still lands inside the Caskroom.
        if bundlePath.contains("/Caskroom/") { return .homebrew }

        if bundlePath == brewInstallPath {
            for prefix in brewPrefixes where caskroomExists("\(prefix)/Caskroom/\(caskToken)") {
                return .homebrew
            }
        }

        guard let key = publicKey, !key.isEmpty, key != unsetKey else { return .unsigned }
        return .direct
    }
}
