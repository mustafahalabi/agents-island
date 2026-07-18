# Agents Island

**A Dynamic Island for your AI coding agents.**

[![CI](https://github.com/mustafahalabi/agents-island/actions/workflows/ci.yml/badge.svg)](https://github.com/mustafahalabi/agents-island/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](#install)

Agents Island turns the MacBook notch into a live control surface for every AI coding agent running on your machine — Claude Code, Codex, Gemini CLI, Aider, Goose, OpenCode, Amp, Cursor Agent, Copilot CLI, and Droid. Glance at the pill to see who's working; hover to see what they're doing; click to jump to the exact terminal tab; approve permission requests without leaving your current app.

Native SwiftUI. No Electron, no dock icon, no cloud — everything is read from local files your agents already write.

> Works on Macs without a notch too (the island floats at the top of the screen), and on any display you choose.

---

## Highlights

**🏝️ The island**
- Collapsed: a slim pill hugging the notch — mascot, agent count, one status dot per agent. Optional *Detailed* style shows live activity and session count in the wings.
- Hover to expand: a session card per agent with Apple-grade morphing animation (container-first stretch, staggered card entrances).
- Visible on all Spaces and over fullscreen apps; optionally hides on fullscreen spaces.

**📇 Rich session cards** *(Claude Code, Codex, and Gemini)*
- AI-generated session title, your last prompt, and a **live activity line** — "Writing IslandView.swift", "Running npm test" — derived from the agent's own transcript.
- Real **working / waiting-for-you / idle** status (not just CPU): Claude's session registry, Codex's task events, Gemini's prompt log.
- **Task checklists** live from Claude's task store and Codex's `update_plan`.
- Running **subagents** with pulsing indicators; **plan previews** rendered from ExitPlanMode with Markdown.
- Chips for agent brand, **AI model** (Opus 4.8, GPT 5 Codex…), **git branch** (worktree-aware), terminal app, and a red **BYPASS** badge when permissions are skipped.

**🖱️ Control, not just monitoring**
- **Click a card → jump to the agent's exact terminal tab/pane** (iTerm, Terminal.app, tmux targeted by tty; other terminals activated).
- **Quick-reply** from the detail view — type a message, it lands in the agent's terminal.
- **Permission approvals**: when Claude Code asks for permission, the island pops open with **Approve / Always Allow / Deny** — the buttons answer the real terminal prompt for you. Powered by a non-blocking hook you install with one click (Settings → Integrations).

**⌨️ Keyboard-first**
- Global session switcher on <kbd>⌃G</kbd> (modifier configurable): press to open, press again or <kbd>↑</kbd><kbd>↓</kbd> to cycle, <kbd>⏎</kbd> to jump, <kbd>esc</kbd> to dismiss.
- <kbd>⌃Y</kbd> / <kbd>⌃A</kbd> / <kbd>⌃N</kbd> approve / always-allow / deny — registered **only while a request is pending**, so they never shadow other apps.
- No Accessibility permission needed for the hotkeys (Carbon `RegisterEventHotKey`).

**📊 Usage quota header**
- `5h 70% ⟳1h20m · 7d 24%` — your Claude rate-limit consumption estimated locally from transcript token counts (ccusage-style 5-hour session blocks and a rolling 7-day window), with per-plan budgets (Pro / Max 5x / Max 20x).

**🔔 Events**
- Completion sound + macOS notification + auto-expand when an agent finishes (each independently toggleable, with smart suppression when you're already looking at that terminal).
- Per-event sounds — session start, task complete, acknowledge, approval needed — with custom sound import and **quiet hours**.

**🌐 SSH remotes**
- Add `user@server` hosts and agents running on remote machines appear in the island with a host chip. Key-auth `BatchMode` scans — it never password-prompts.

**🔄 Automatic updates**
- Checks once a day and offers the new version in place — signed appcast, EdDSA-verified download, nothing installed without your confirmation.
- Installed with Homebrew? It detects the cask and defers to `brew upgrade --cask agents-island` instead, so the two never fight.

**⚙️ Settings for everything**
- A full sidebar settings window: hover behavior, dismissal, display picker for multi-screen setups, panel sizing and fonts, per-card toggles, notch fine-tuning, sounds, usage plan, per-agent enable/disable, shortcuts, SSH hosts.

---

## Install

Requires **macOS 14+** (Apple Silicon or Intel).

**Homebrew:**

```sh
brew install --cask mustafahalabi/tap/agents-island
```

(Homebrew ≥ 4.6 asks you to trust third-party taps once: `brew trust mustafahalabi/tap`.)

**One line, no Homebrew** (builds locally with the Xcode Command Line Tools you already have — no Gatekeeper warnings):

```sh
curl -fsSL https://raw.githubusercontent.com/mustafahalabi/agents-island/main/install.sh | bash
```

**Prebuilt** — grab `AgentsIsland.zip` from the [latest release](https://github.com/mustafahalabi/agents-island/releases/latest) and drag it to /Applications. v0.2.2 and v0.4.6+ are **signed and notarized** — they open like any Mac app, no warnings.

> [!WARNING]
> **v0.3.0 through v0.4.5 are broken — don't use them.** They were signed but
> never notarized, so macOS blocks them and moves the app to the Trash on first
> launch. Upgrade to v0.4.6 or later.

**From a checkout:**

```sh
git clone https://github.com/mustafahalabi/agents-island.git
cd agents-island
./make-app.sh --install   # builds, installs to /Applications, launches
```

The app registers itself as a login item on first launch (toggleable in Settings). Uninstall by quitting from the menu bar and deleting `/Applications/AgentsIsland.app`.

To enable **permission approvals**, open Settings → Integrations → Install, then restart any running Claude Code sessions.

### Permissions macOS will ask for (each one-time, each optional)

| Prompt | Triggered by | Grants |
|---|---|---|
| Automation (iTerm / Terminal) | first click-to-jump | selecting the right tab, sending replies |
| Accessibility | approving in Terminal.app & other terminals | synthesizing the answer keystroke |
| Notifications | first launch | completion notifications |

iTerm and tmux need nothing beyond Automation — sessions are targeted precisely by tty.

---

## How it works

Everything is local. The key insight is that coding agents already publish their state to disk:

| Source | Provides |
|---|---|
| `~/.claude/sessions/` | pid → session, cwd, **busy/idle status** |
| `~/.claude/projects/**/*.jsonl` | titles, prompts, live tool activity, subagents, plans, models, token usage |
| `~/.claude/tasks/` | task checklists |
| `~/.codex/sessions/**/rollout-*.jsonl` | Codex status (task events), activity, plans, model |
| `~/.gemini/tmp/<hash>/` | Gemini prompts and saved chats |
| `ps` / `lsof` | agent discovery, CPU, tty, working directory, hosting terminal |
| `ssh host 'ps …'` | remote sessions |

Transcript parsing reads only the file tails (agent transcripts grow to 100MB+) and caches by mtime; the usage tracker backfills once and then reads only appended bytes. Polling is every 2s (configurable) on a utility queue, and the UI only updates when something actually changed.

Your agent data never leaves your Mac — no telemetry, no analytics, no cloud sync.

The one network connection the app makes is the update check: once a day it
fetches a signed appcast from GitHub Releases, and downloads are verified
against the project's EdDSA key before anything is installed. It sends nothing
but the request itself, and you can turn it off in **Settings → About**.
Homebrew installs skip it entirely and defer to `brew upgrade`.

---

## Development

```sh
swift build          # debug build
swift run            # run without a bundle (some features need the .app)
./make-app.sh        # release build → dist/AgentsIsland.app → launch
```

Plain Swift Package — no Xcode project. The `.app` bundle exists so macOS TCC permissions attach to a stable bundle ID (`dev.mustafa.agents-island`).

```
Sources/AgentsIsland/
  App.swift             @main, menu bar item, app lifecycle
  NotchPanel.swift      borderless panel: screen targeting, fullscreen hiding
  NotchShape.swift      Dynamic Island silhouette + morph transitions
  IslandView.swift      pill, cards, detail view, choreography
  AgentMonitor.swift    process scanner, lifecycle events
  ClaudeSessions.swift  Claude Code readers (registry, transcript, tasks)
  CodexSessions.swift   Codex rollout reader
  GeminiSessions.swift  Gemini per-project reader
  ApprovalCenter.swift  permission approvals (hook, spool, tty answers)
  UsageTracker.swift    5h/7d quota estimation
  RemoteMonitor.swift   SSH host scanning
  TerminalBridge.swift  tty-targeted jump / send / answer
  HotKeys.swift         global hotkeys + keyboard switcher
  SoundEngine.swift     event sounds, quiet hours, custom imports
  SettingsView.swift    sidebar settings window
```

See [PROJECT.md](PROJECT.md) for the full design log and data-source documentation.

---

## Contributing

Contributions are welcome. Start with **[CONTRIBUTING.md](CONTRIBUTING.md)** — it
covers the local setup, the branch/PR flow, and the two hard constraints (no
third-party dependencies, nothing leaves your machine).

- `main` is protected: every change lands through a reviewed pull request with green CI.
- Adding a new agent? There's a [dedicated issue template](https://github.com/mustafahalabi/agents-island/issues/new?template=new_agent.yml), and [PROJECT.md](PROJECT.md) documents every agent's on-disk data sources.
- By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
- Found a security issue? Please report it [privately](SECURITY.md), not as an issue.

---

## License

[MIT](LICENSE) © Mustafa Halabi and Mohammad Hammoud

---

## Acknowledgements

Interaction design inspired by [Vibe Island](https://vibeisland.app/). Agent brand icons from the MIT-licensed [lobehub icon set](https://github.com/lobehub/lobe-icons). Usage estimation approach follows the [ccusage](https://github.com/ryoppippi/ccusage) methodology.
