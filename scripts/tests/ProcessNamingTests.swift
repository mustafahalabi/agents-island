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

        if failures == 0 {
            print("✅ ProcessNamingTests: all passed (space-containing app paths resolve)")
        } else {
            print("❌ ProcessNamingTests: \(failures) failure(s)"); exit(1)
        }
    }
}
