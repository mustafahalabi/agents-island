# Agents Island — Project Log

A macOS **Dynamic Island for AI coding agents**, inspired by [vibeisland.app](https://vibeisland.app/).
A notch-hugging panel shows every AI agent running on the Mac — Claude Code, Codex, Gemini CLI, and others — with live status, session details, task checklists, and click-to-jump to the agent's terminal.

- **Stack**: native SwiftUI, plain Swift Package (no Xcode project), macOS 14+, Apple Silicon.
- **Location**: `~/Documents/projects/agents-island`
- **Run**: `./make-app.sh` (builds release, wraps into `dist/AgentsIsland.app`, launches). Dev loop: `swift build` / `swift run`.

---

## What it does

### The island
- **Collapsed**: a slim black pill wrapping the physical notch. Left wing: pixel-bot mascot + agent count. Right wing: one status dot per agent (max 4, then `+N`). Faint green ambient glow when any agent is working.
- **Hover → expanded**: a wide (530pt) panel listing every agent session as a card.
- **Header**: `● N working · ● N waiting` summary + gear button (settings).
- Works on Macs without a notch (floating pill, auto-repositions on display changes).
- Panel is a borderless, non-activating `NSPanel` at `.screenSaver` level, visible on all Spaces and over fullscreen apps.

### Session cards (Claude Code, **Codex**, and **Gemini** sessions get the rich treatment)
- **Brand icon** of the agent (real logos, MIT-licensed lobehub icon set) with a status-dot badge.
- **AI-generated session title** (falls back to project folder name).
- **"You: …"** — your last prompt.
- **Live activity line** in blue while working — "Writing IslandView.swift", "Running a command" — derived from unresolved tool calls in the transcript.
- **Task checklist** — live todos with checkboxes: `Tasks (4 done, 2 in progress, 1 open)`; blue dot = in progress, empty box = open, checked + strikethrough = done.
- **Chips**: red `BYPASS` badge (when running with permissions bypassed), agent chip, terminal app chip (iTerm, Ghostty, Warp, Terminal, VS Code, tmux…), uptime.
- **Click a card → jumps to the agent's terminal** — the exact window/tab/pane in iTerm/Terminal.app, the right pane in tmux, app activation otherwise.
- **Chevron button (on hover) → detail view**: scrollable conversation tail (your messages + agent replies), full task list, live activity spinner, jump chip.
- Cards sort working → waiting → idle; idle cards are visually dimmed.

### Statuses
- 🟢 **Working** — Claude: session registry says `busy`. Codex: rollout has `task_started` without a closing `task_complete`, or an unresolved function call. Gemini: CPU >3% or a prompt in the last 20s.
- 🟠 **Waiting for you** — turn finished, no reply yet.
- ⚪️ **Idle** — no activity for 30+ minutes.
- Other agents fall back to a CPU heuristic (>3% = working, never "waiting").

### Events & system integration
- **Completion events** (working → waiting): plays a system sound (configurable) and auto-expands the island for 5s; also posts a **macOS notification** ("Claude finished — *fix auth bug* — waiting for you").
- **Menu bar item**: shows `✦ N` while agents work; menu lists all sessions (🟢/🟡/⚪ + title) — click to jump; Refresh / Settings / Quit.
- **Launch at login**: registered via `SMAppService` on first launch; toggle in settings.
- **Single-instance guard**: a new launch terminates older copies.
- **Branded app icon**: the pixel-bot mascot rendered to `AppIcon.icns` (regenerate: `swift scripts/gen-icon.swift`).

### Settings (own window — gear, menu bar, or ⌘,; Vibe-Island-style sidebar, forced dark)
- **General**: launch at login · expand-on-hover + hover duration slider · smart suppression (no auto-expand when the agent's terminal is frontmost) · auto-expand on completion · hide in fullscreen · auto-hide when empty · auto-collapse · auto-reveal dwell (2–15s) · dismiss reveal on outside click · idle session cleanup (30m/1h/2h) · disable click-to-jump · refresh interval (1–5s).
- **Notifications**: agent-finished · session-started.
- **Display**: collapsed pill style **Clean / Detailed** (detailed shows live activity + session count in the wings) · **display picker for multi-screen setups** (Automatic = notched display, or any connected screen by name) · content font size (10–13pt) · max panel width/height (list scrolls past the cap) · session-card toggles: last message, live activity, **AI model chip**, **git branch chip**, terminal chip, tasks · max visible sessions · notch width/height fine-tuning offsets.
- **Sound**: master toggle + volume · per-event sounds (session start / task complete / task acknowledge) with preview buttons · **My Sounds** custom import (copied to Application Support) · quiet hours (crosses midnight).
- **Agents**: enable/disable each of the 10 tracked agents.
- **Shortcuts**: modifier picker (⌃/⌥/⌘) · master enable · **global session switcher** `mod+G` (Carbon hotkey, no Accessibility permission: press to open, press again / arrows to cycle, ⏎ or T jumps to the terminal, esc closes; `mod+⇧G` cycles backwards).
- **About**: mascot, version, local-data statement.

### New data on cards
- **AI model chip** — parsed from `message.model` in the transcript tail ("claude-opus-4-8" → "Opus 4.8").
- **Git branch chip** — read from `<cwd>/.git/HEAD` (worktree `.git`-file indirection handled), no git binary spawned.

---

## How it works (data sources)

The key discovery: **Claude Code publishes everything needed, locally**.

| Source | What it provides |
|---|---|
| `~/.claude/sessions/<pid>.json` | Live registry: pid → sessionId, cwd, derived name, **status (busy/idle)**, statusUpdatedAt |
| `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl` | Transcript: `ai-title`, `last-prompt`, assistant `tool_use` entries (unresolved one = current activity), conversation text |
| `~/.claude/tasks/<sessionId>/<n>.json` | **Current task system**: one JSON per task (`subject`, `status`) — the transcript's `TodoWrite` is only the legacy fallback |
| `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | **Codex rollouts**: `session_meta` (cwd, git), `turn_context` (model), `response_item` (messages, function calls → activity, `update_plan` → task checklist), `event_msg` (`task_started`/`task_complete` → status, `user_message` → prompt). pid→rollout mapped via lsof of the open file, falling back to cwd match; handles both wrapped (`type`/`payload`) and older flat record shapes. Env-context/instruction injections filtered from prompts. |
| `~/.gemini/tmp/<sha256-of-cwd>/` | **Gemini per-project data**: `logs.json` → last user prompt + prompt age (drives waiting/idle split and a 20s post-prompt "working" grace on top of the CPU heuristic — Gemini writes no task events); newest `checkpoint*.json` / `chats/*.json` → detail-view conversation (Content shape `{role, parts[].text}`, plus `history`/`messages` wrappers); model from `-m/--model` process args, falling back to settings.json. |
| `ps -axwwo pid,ppid,pcpu,tty,etime,args` | Agent discovery (by executable basename, incl. node/bun/python wrappers), CPU, tty, uptime, BYPASS flag detection |
| `lsof -a -d cwd -p …` | Working directory for non-Claude agents |
| ppid ancestry walk | Hosting terminal app (first `.app` ancestor, or tmux/screen/zellij) |

- Encoded cwd = every non-alphanumeric character replaced with `-`.
- Transcript parsing reads only the last 192–384KB (files grow to 100MB+), cached by mtime.
- Polling every 2s (configurable) on a utility queue; UI only updates when the model actually changes.

### Terminal bridge (jump / send)
Targets the exact session by **tty** (`ps -o tty`):
- **iTerm**: AppleScript — match `tty of session`, `select` window/tab/session (jump), `write text` (send).
- **Terminal.app**: match `tty of tab`, `set selected tab` (jump), `do script in tab` (send).
- **tmux**: `list-panes -a` by pane_tty → `switch-client` / `select-pane` / `send-keys`.
- **Others** (Ghostty, Warp, kitty…): app activation (+ System Events keystrokes for send).
- Requires the macOS Automation permission — the reason the app ships as a bundled `.app` with a stable bundle ID (`dev.mustafa.agents-island`).

---

## Design decisions & iterations

1. **v1**: rounded-rect pill, avatar circles, CPU-only status. Verdict: chips wrapped mid-word ("BYPAS S"), titles truncated, repeated avatars were noise.
2. **Card redesign**: status dot + title + time on line 1; message on line 2; activity left / fixed-size chips bottom-right; hover highlight + pointing cursor; smarter title fallbacks (AI title → folder name → "Claude session").
3. **Pixel-bot mascot**: originally replaced status dots with an animated code-drawn pixel robot (string-bitmap sprites in `PixelBot.swift` — dances when working, blinks when waiting, sleeps when idle). Considered CC0 sprite packs (Kenney/itch.io) but code-drawn = tintable, animatable, license-free, brandable.
4. **Real brand icons**: user preferred actual agent logos on cards — lobehub icon set, with the mascot retained in the collapsed pill + app icon. Aider/Droid have no icon → colored avatar fallback.
5. **Reply-from-island** was built (text field routed to the agent's tty), then **replaced by click-to-jump** as the primary interaction at user request. The `TerminalBridge.send` plumbing remains for a future quick-reply.
6. **Settings window**: SwiftUI's `Settings` scene can't be opened programmatically from an accessory app on modern macOS (`showSettingsWindow:` is dead) → self-managed `NSWindow`.
7. **The premium island** (final form):
   - **`NotchShape`** — authentic Dynamic Island silhouette: top corners flare *outward* into the notch/menu bar, bottom corners round inward; both radii animate.
   - **Materials**: near-black vertical gradient + 1px hairline stroke brightening toward the bottom + deep drop shadow + status-tinted glow.
   - **Apple-level choreography**: 90ms hover-intent delay (no accidental opens) · 150ms exit grace (no edge flicker) · asymmetric springs (fluid 0.55s open with gentle overshoot; quick damped close) · **container-first morphing** — the shape stretches first, content materializes ~120ms later with blur+fade, cards stagger in ~50ms apart; on close, content vanishes fast then the shape contracts.
8. **Tasks**: initially parsed `TodoWrite` from transcripts — user saw nothing because current Claude Code uses the **task store** (`~/.claude/tasks/`). Now store-first, transcript fallback.
9. **Settings 2.0** (modeled on Vibe Island screenshots): custom dark sidebar window (no TabView), `SSection`/`SRow` building blocks, per-event sound routing through a central `SoundEngine`, Carbon `RegisterEventHotKey` for the switcher (works from an accessory app without Accessibility permission — key events intercepted in `NSPanel.sendEvent` because SwiftUI's ScrollView would swallow arrows before `keyDown`). Fullscreen hiding is a heuristic: the target screen's `visibleFrame` reaching the top edge means the menu bar is hidden (documented caveat: users who auto-hide the menu bar should keep the setting off). Lifecycle events (`agentStarted`/`agentCompleted`/`agentAcknowledged`) are suppressed on the first scan so a fresh launch doesn't fire a sound per already-running agent.

---

## File map

```
Package.swift               SPM manifest (macOS 14+, bundles Resources/agents icons)
make-app.sh                 release build → dist/AgentsIsland.app → launch
scripts/gen-icon.swift      renders mascot → assets/icon-1024.png (→ AppIcon.icns)
assets/AppIcon.icns         app icon
Sources/AgentsIsland/
  App.swift                 @main, MenuBarExtra (live count + jump menu), AppDelegate
                            (single-instance, login item, notifications, panel setup)
  NotchPanel.swift          borderless non-activating panel: screen targeting
                            (display picker), notch tuning offsets, fullscreen
                            hiding, switcher key interception (sendEvent)
  NotchShape.swift          Dynamic Island silhouette + content transitions + stagger
  IslandView.swift          collapsed pill (clean/detailed) / expanded cards /
                            detail view / hover+reveal choreography / switcher ring
  AgentIconView.swift       brand logo + status badge (bundle-cached)
  PixelBot.swift            animated pixel mascot (string-bitmap sprites)
  Agent.swift               AgentKind (10 agents), AgentStatus, AgentSession, Todo
  AgentMonitor.swift        ps/lsof scanner, terminal detection, lifecycle events
                            (started/completed/acknowledged), git branch reader
  ClaudeSessions.swift      session registry, transcript tail parser (incl. model
                            id), task store reader
  CodexSessions.swift       Codex rollout reader: pid→rollout (lsof/cwd), tail
                            parser (status, activity, plan todos, model, messages)
  GeminiSessions.swift      Gemini per-project reader: cwd→sha256 dir, logs.json
                            prompts, saved-chat transcripts, settings model
  TerminalBridge.swift      tty-targeted jump/send (AppleScript, tmux), frontmost
                            terminal check for smart suppression
  SoundEngine.swift         per-event sounds, volume, quiet hours, custom imports
  HotKeys.swift             Carbon global hotkeys + SwitcherState (keyboard nav)
  Preferences.swift         UserDefaults keys + defaults + notification names
  SettingsView.swift        sidebar settings: General / Notifications / Display /
                            Sound / Agents / Shortcuts / About
  SettingsWindow.swift      self-managed settings NSWindow (dark, 780×640)
  LoginItem.swift           SMAppService launch-at-login
```

---

## Roadmap (discussed, not yet built)

- **Permission approval buttons** — approve/deny Claude Code tool requests from the island (needs a PreToolUse hook signaling the app). *Task #2, in progress.* The Shortcuts pane already reserves Approve/Deny keys for this.
- **Usage quota header** — 5h/7d limit percentages + reset countdown, Vibe-style. *Task #3.*
- Quick-reply revival (plumbing already in `TerminalBridge.send`).
- Plan preview with Markdown rendering; SSH remotes.
- Subagent / Agent-Team visibility on cards (Vibe parity).
- Install to `/Applications`.
- Two-stage expansion (width first, then height) if the stretch should read even stronger.

### Done since (Settings 2.0 sweep, 2026-07-11)
- ~~Global hotkey to toggle the island~~ → `mod+G` switcher. ~~Hide-in-fullscreen~~ → General pane. ~~Custom sound packs~~ → My Sounds import. Multi-screen display picker shipped.

## Gotchas

- Login item points at `dist/AgentsIsland.app` — re-run `./make-app.sh` if the project moves.
- First jump to iTerm/Terminal triggers the macOS Automation prompt (one-time approve).
- `screencapture` from this terminal lacks screen-recording permission — UI must be eyeballed.
- Git repo initialized; **nothing committed yet**.
