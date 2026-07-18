// Tests for the gate that decides whether the app may update itself.
//
// This one matters more than its size suggests: getting it wrong means either
// self-updating on top of a Homebrew cask (which desyncs the Caskroom manifest
// and makes the next `brew upgrade` fight the self-installed copy), or trusting
// a download when no verification key was baked in.
//
// Compiled against the real InstallChannel.swift by scripts/run-tests.sh.
import Foundation

@main
struct InstallChannelTests {
    static var failures = 0

    static let key = "9kZ1Xb+realLookingBase64Key/PublicEdDSAvalue="

    /// `caskroom` lists the Caskroom paths that "exist" for this scenario.
    static func expect(
        _ label: String,
        bundlePath: String,
        publicKey: String?,
        caskroom: Set<String> = [],
        want: Install.Channel,
        _ line: Int = #line
    ) {
        let got = Install.resolve(
            bundlePath: bundlePath,
            publicKey: publicKey,
            caskroomExists: { caskroom.contains($0) }
        )
        if got != want {
            failures += 1
            print("FAIL:\(line)  \(label) = \(got), want \(want)")
        }
    }

    static func main() {
        let appleSilicon = "/opt/homebrew/Caskroom/agents-island"
        let intel = "/usr/local/Caskroom/agents-island"

        // A plain download with a key baked in: the only case that self-updates.
        expect("direct download",
               bundlePath: "/Applications/AgentsIsland.app",
               publicKey: key,
               want: .direct)

        // Homebrew moves the app to /Applications, so the path looks identical
        // to a direct install — only the Caskroom entry gives it away.
        expect("brew on Apple Silicon",
               bundlePath: "/Applications/AgentsIsland.app",
               publicKey: key,
               caskroom: [appleSilicon],
               want: .homebrew)

        expect("brew on Intel",
               bundlePath: "/Applications/AgentsIsland.app",
               publicKey: key,
               caskroom: [intel],
               want: .homebrew)

        // Older casks symlinked into /Applications; the resolved path lands
        // inside the Caskroom even when no metadata directory is found.
        expect("legacy symlinked cask",
               bundlePath: "/opt/homebrew/Caskroom/agents-island/0.4.5/AgentsIsland.app",
               publicKey: key,
               want: .homebrew)

        // Homebrew must win over a valid key — a signed brew install still
        // defers to `brew upgrade` rather than replacing itself.
        expect("brew beats a valid key",
               bundlePath: "/Applications/AgentsIsland.app",
               publicKey: key,
               caskroom: [appleSilicon, intel],
               want: .homebrew)

        // No key means no way to verify a download, so updates stay off.
        expect("placeholder key",
               bundlePath: "/Applications/AgentsIsland.app",
               publicKey: "UNSET",
               want: .unsigned)

        expect("missing key",
               bundlePath: "/Applications/AgentsIsland.app",
               publicKey: nil,
               want: .unsigned)

        expect("empty key",
               bundlePath: "/Applications/AgentsIsland.app",
               publicKey: "",
               want: .unsigned)

        // A dev build run straight out of dist/ must not try to update itself.
        expect("local dist build",
               bundlePath: "/Users/dev/agents-island/dist/AgentsIsland.app",
               publicKey: "UNSET",
               want: .unsigned)

        // Regression: maintainers usually have the cask installed *and* run a
        // local build. A stray Caskroom entry must not make the dist build look
        // brew-managed — that would disable the updater on the one build we
        // need to be able to test it with.
        expect("dist build while the cask is also installed",
               bundlePath: "/Users/dev/agents-island/dist/AgentsIsland.app",
               publicKey: key,
               caskroom: [appleSilicon],
               want: .direct)

        // Same, for a signed build the user dragged somewhere else entirely.
        expect("signed build outside /Applications with cask present",
               bundlePath: "/Users/dev/Desktop/AgentsIsland.app",
               publicKey: key,
               caskroom: [appleSilicon],
               want: .direct)

        // A cask install of an unsigned build is still brew's to manage.
        expect("brew without a key",
               bundlePath: "/Applications/AgentsIsland.app",
               publicKey: "UNSET",
               caskroom: [appleSilicon],
               want: .homebrew)

        if failures == 0 {
            print("✅ InstallChannelTests: all passed (self-update gated to direct installs)")
        } else {
            print("❌ InstallChannelTests: \(failures) failure(s)")
            exit(1)
        }
    }
}
