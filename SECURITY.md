# Security Policy

## Supported versions

Security fixes land on the latest release. Older versions are not backported —
please update to the current release before reporting.

## Reporting a vulnerability

**Do not open a public issue for a security vulnerability.**

Report it privately through GitHub's
[private vulnerability reporting](https://github.com/mustafahalabi/agents-island/security/advisories/new)
form. That opens a draft advisory only you and the maintainers can see.

Please include:

- What the issue is and roughly how severe you think it is
- Steps to reproduce, or a proof of concept
- The version of Agents Island and your macOS version
- Anything you know about mitigations or workarounds

You can expect an acknowledgement within **72 hours** and an assessment within
**7 days**. If a fix is warranted we'll work on it privately, credit you in the
advisory (unless you'd rather stay anonymous), and disclose once a patched
release is out.

## Scope

Agents Island runs locally and reads files your AI coding agents already write
to disk. Things that are especially interesting to report:

- Anything that causes data to leave the machine — the app is designed to make
  zero outbound network calls except SSH scans the user explicitly configures
- Command injection through session data, file paths, git branch names, or any
  other content read from agent transcripts
- Issues in the terminal bridge — the code that jumps to a tty, sends text, or
  answers permission prompts on the user's behalf
- Issues in the permission-approval hook or its spool files
- Privilege escalation, or abuse of the app's TCC permissions (Accessibility,
  Automation, Notifications)
- SSH remote-scanning behavior that leaks credentials or executes unintended
  commands on a remote host

Out of scope:

- Vulnerabilities in the AI coding agents themselves (Claude Code, Codex,
  Gemini CLI, etc.) — report those to their respective projects
- Attacks that require an attacker to already have local code execution as the
  user, since at that point they can read the same files the app reads
- Missing hardening that has no demonstrated impact
