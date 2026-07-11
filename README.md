# Agents Island 🏝️

A Dynamic Island for your Mac's notch that shows every AI coding agent running on your machine — Claude Code, Codex, Gemini CLI, Aider, Goose, OpenCode, Amp, Cursor Agent, Copilot CLI, Droid.

- **Collapsed**: a slim pill hugging the notch with the agent count and per-agent status dots.
- **Hover to expand**: a card listing each agent with its project directory, uptime, and a live Working / Idle status.
- Works on Macs without a notch too (floating pill at the top of the screen).
- Menu bar item (✨) to refresh or quit.

## Run

```sh
swift run -c release
```

## How it works

Every 2 seconds it scans the process table (`ps`) for known agent CLIs — matching the executable name directly or through interpreters like `node`/`python` — grabs each agent's working directory via `lsof`, and infers status from CPU usage (busy agents burn CPU; agents waiting at a prompt idle near zero).

## Roadmap ideas

- Richer Claude Code status by reading `~/.claude/projects` session files (current tool call, waiting-for-permission, etc.)
- Click a row to focus the agent's terminal window
- Notifications when an agent finishes or needs input
- Proper `.app` bundle + login item
