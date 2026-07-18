import Foundation

/// Turning a `ps` args string into the hosting app's name.
///
/// `ps` prints the executable path and its arguments space-separated, and macOS
/// application paths routinely contain spaces — `/Applications/Visual Studio
/// Code.app/Contents/MacOS/Electron`. Splitting on the first space to recover
/// the executable therefore truncates it to `/Applications/Visual`, and every
/// lookup downstream fails.
///
/// That was the live behaviour: VS Code, Cursor and Windsurf sessions all
/// resolved to no terminal app at all, so click-to-jump and inline reply
/// silently did nothing for them, and the card showed no terminal chip. iTerm
/// and Terminal worked purely because their bundle paths have no spaces. The
/// giveaway was that the `"Visual Studio Code"` rename in the old
/// `appBundleName` could never run — the string never survived the split.
enum ProcessNaming {

    /// Names macOS reports differently from how the UI should show them.
    static let displayNames: [String: String] = [
        "Visual Studio Code": "VS Code",
        "Code": "VS Code",
        "Code - Insiders": "VS Code",
        "iTerm2": "iTerm",
    ]

    /// The hosting `.app` bundle name in a full `ps` args string, if any.
    ///
    /// Searches the whole string rather than a space-split first token, so
    /// bundle paths containing spaces resolve. Path components are separated by
    /// `/`, and a space inside a component is part of the name, so splitting on
    /// `/` keeps "Visual Studio Code.app" intact.
    static func appBundleName(fromCommand command: String) -> String? {
        for component in command.split(separator: "/") where component.hasSuffix(".app") {
            let raw = String(component.dropLast(4))
            return displayNames[raw] ?? raw
        }
        return nil
    }

    /// The executable path alone — everything up to the first argument.
    ///
    /// Only meaningful for multiplexers (tmux/screen/zellij), whose binaries
    /// live at space-free paths; it exists so their basename match is not
    /// confused by trailing arguments.
    static func executableToken(_ command: String) -> String {
        String(command.split(separator: " ").first ?? "")
    }

    /// Last path component of the executable, lowercased — used to spot
    /// terminal multiplexers in the parent chain.
    static func executableBasename(_ command: String) -> String {
        (executableToken(command) as NSString).lastPathComponent.lowercased()
    }

    /// Is this a GUI application's background helper rather than a CLI agent?
    ///
    /// `detect` already rejects an executable path inside an `.app` bundle, but
    /// Electron apps rewrite `argv[0]` to a display string, so `ps` reports no
    /// path at all:
    ///
    ///     Cursor Helper: shared-process
    ///     Cursor Helper (Plugin): extension-host (user) …
    ///
    /// The first token is then plain `Cursor`, which matches the registered
    /// alias for the cursor-agent kind — so every helper Cursor spawns was
    /// listed as a running agent. Eight ghost sessions on an idle machine with
    /// only the editor open.
    ///
    /// Two conditions together identify them, and both are needed:
    ///
    /// - **the parent is a GUI app binary.** A real CLI agent is launched from
    ///   a shell, so its immediate parent is `/bin/zsh` or similar, never
    ///   `/Applications/Foo.app/Contents/MacOS/Foo`. An agent running in an
    ///   editor's integrated terminal is still a child of a shell.
    /// - **there is no controlling terminal.** Requiring this on its own would
    ///   be too broad, and requiring only the parent check would drop an agent
    ///   from a terminal configured to exec it directly instead of a shell.
    static func isGUIHelper(tty: String?, parentCommand: String?) -> Bool {
        guard tty == nil, let parentCommand else { return false }
        return parentCommand.contains(".app/")
    }
}
