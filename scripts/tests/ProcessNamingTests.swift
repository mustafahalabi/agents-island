// Tests for resolving the hosting app from a `ps` args string.
//
// The bug these cover: the args string was split on the first space to recover
// the executable path, but macOS app bundles routinely contain spaces —
// "/Applications/Visual Studio Code.app/..." truncated to "/Applications/Visual".
// VS Code, Cursor and Windsurf sessions therefore resolved to no terminal app,
// so click-to-jump and inline reply silently did nothing for them.
//
// Compiled against the real ProcessNaming.swift by scripts/run-tests.sh.
import Foundation

@main
struct ProcessNamingTests {
    static var failures = 0

    static func fail(_ message: String, _ line: Int = #line) {
        failures += 1
        print("FAIL:\(line)  \(message)")
    }

    static func expect(_ command: String, _ want: String?, _ line: Int = #line) {
        let got = ProcessNaming.appBundleName(fromCommand: command)
        if got != want {
            failures += 1
            print("FAIL:\(line)  \(command)\n        got  \(got ?? "nil")\n        want \(want ?? "nil")")
        }
    }

    static func main() {
        // The regression: a bundle path containing spaces, with arguments after it.
        expect("/Applications/Visual Studio Code.app/Contents/MacOS/Electron --type=renderer",
               "VS Code")
        expect("/Applications/Visual Studio Code.app/Contents/MacOS/Electron", "VS Code")

        // Other space-containing bundles that were equally broken.
        expect("/Applications/Cursor.app/Contents/MacOS/Cursor", "Cursor")
        expect("/Users/me/Applications/Windsurf.app/Contents/MacOS/Electron", "Windsurf")
        expect("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "Google Chrome")

        // Terminals that happened to work before must keep working.
        expect("/Applications/iTerm.app/Contents/MacOS/iTerm2", "iTerm")
        expect("/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", "Terminal")
        expect("/Applications/Ghostty.app/Contents/MacOS/ghostty", "Ghostty")

        // Display-name normalisation.
        expect("/Applications/Code - Insiders.app/Contents/MacOS/Electron", "VS Code")

        // Non-app processes have no bundle name.
        expect("/bin/zsh -l", nil)
        expect("/opt/homebrew/bin/tmux new-session", nil)
        expect("", nil)

        // Multiplexer detection uses the executable token, so trailing
        // arguments must not defeat the basename match.
        let bases: [(String, String)] = [
            ("/opt/homebrew/bin/tmux -CC attach", "tmux"),
            ("/usr/bin/screen -r work", "screen"),
            ("/opt/homebrew/bin/zellij attach main", "zellij"),
            ("/bin/zsh -l", "zsh"),
        ]
        for (command, want) in bases {
            let got = ProcessNaming.executableBasename(command)
            if got != want {
                failures += 1
                print("FAIL: executableBasename(\(command)) = \(got), want \(want)")
            }
        }

        // --- GUI helpers must not be listed as agents -------------------------
        // Electron rewrites argv[0] to a display string, so `ps` shows no path
        // and the first token is plain "Cursor" — which matches the cursor-agent
        // alias. On an idle machine with only the editor open this produced
        // eight ghost sessions. Real argv taken from a live process table.
        let cursorApp = "/Applications/Cursor.app/Contents/MacOS/Cursor"
        let ghosts = [
            "Cursor Helper: shared-process",
            "Cursor Helper: fileWatcher [1:81d94e91505b53393daf61fdaf3407b4]",
            "Cursor Helper: mcp-process",
            "Cursor Helper: terminal pty-host",
            "Cursor Helper (Plugin): extension-host (user) live-love-recycle [1-1]",
            "Cursor Helper (Plugin): extension-host (agent-exec)",
        ]
        for ghost in ghosts where !ProcessNaming.isGUIHelper(tty: nil, parentCommand: cursorApp) {
            failures += 1
            print("FAIL: GUI helper would be listed as an agent: \(ghost)")
        }

        // A real agent in a terminal must survive: it has a tty and its parent
        // is a shell, not an app bundle.
        if ProcessNaming.isGUIHelper(tty: "ttys008", parentCommand: "/bin/zsh -il") {
            fail("a real agent in a terminal was treated as a GUI helper")
        }
        // Even inside an editor's integrated terminal, the parent is a shell.
        if ProcessNaming.isGUIHelper(tty: "ttys015", parentCommand: "-/bin/zsh") {
            fail("an agent in an integrated terminal was treated as a GUI helper")
        }
        // A tty is enough on its own, even when the parent IS the app bundle —
        // covers a terminal configured to exec the agent instead of a shell.
        if ProcessNaming.isGUIHelper(tty: "ttys003", parentCommand: cursorApp) {
            fail("an agent with a tty must never be dropped")
        }
        // Headless agents whose parent is a shell are not GUI helpers; the
        // separate isHeadless check owns that decision.
        if ProcessNaming.isGUIHelper(tty: nil, parentCommand: "/bin/bash") {
            fail("a tty-less agent under a shell must not be dropped here")
        }
        // Unknown parent: not enough evidence to drop.
        if ProcessNaming.isGUIHelper(tty: nil, parentCommand: nil) {
            fail("unknown parent should not be treated as a GUI helper")
        }

        if failures == 0 {
            print("✅ ProcessNamingTests: all passed (app paths resolve, GUI helpers excluded)")
        } else {
            print("❌ ProcessNamingTests: \(failures) failure(s)"); exit(1)
        }
    }
}
