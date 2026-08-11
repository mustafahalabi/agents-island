# Contributing to Agents Island

Thanks for taking the time to contribute. This is a native macOS SwiftUI app with
no build system beyond SwiftPM, so getting started is short.

Agents Island is maintained by [@mustafahalabi](https://github.com/mustafahalabi)
(Mustafa Halabi) and [@Mhmdhammoud](https://github.com/Mhmdhammoud) (Mohammad
Hammoud). Both are code owners, so either can review and merge.

## Ground rules

- `main` is protected. Nobody pushes to it directly — every change lands through a
  pull request that passes CI.
- Be kind. The [Code of Conduct](CODE_OF_CONDUCT.md) applies everywhere in this project.
- Found a security issue? Don't open an issue — see [SECURITY.md](SECURITY.md).

## Getting set up

Requires **macOS 14+** and a Swift toolchain (Xcode 15+ command line tools).

```sh
git clone https://github.com/mustafahalabi/agents-island.git
cd agents-island
swift build            # debug build
./make-app.sh          # release build → dist/AgentsIsland.app → launch
./scripts/run-tests.sh # logic tests
```

Some features (TCC permissions, login item, notifications) only behave correctly
from the `.app` bundle, so prefer `./make-app.sh` when testing those.

## Making a change

1. **Open an issue first** for anything non-trivial. A bug fix or typo can go
   straight to a PR; a new feature or a refactor is worth agreeing on before you
   write it, so your time isn't wasted.
2. **Branch off `main`** using a descriptive name:
   - `feat/ssh-host-groups`
   - `fix/notch-offset-external-display`
   - `docs/readme-install`
3. **Keep the diff focused.** One logical change per PR. Unrelated cleanups in a
   separate PR make review far faster.
4. **Match the surrounding code.** This codebase has a consistent style — plain
   SwiftUI, no third-party dependencies, comments that explain *why* rather than
   *what*. Read the file you're editing before adding to it.
5. **Add or update tests** when you change logic that `scripts/tests/` covers
   (agent detection, question parsing). See `scripts/run-tests.sh` for how test
   targets are wired — this is a single executable target, so tests compile the
   source files they cover directly.
6. **Run the checks locally** before pushing:
   ```sh
   swift build
   ./scripts/run-tests.sh
   ./make-app.sh --no-launch
   ```

## Opening the pull request

- Fill in the PR template — especially *how you tested it*. For UI changes,
  attach a screenshot or a short screen recording; the island is a visual
  component and reviewing it from a diff alone is guesswork.
- Link the issue it closes (`Closes #123`).
- CI must be green. It builds the app bundle and runs the test suites on macOS.
- A maintainer reviews and merges. Please don't force-push after review has
  started — push follow-up commits instead so reviewers can see what changed.
  Everything is squashed on merge, so the branch history stays your own business.

## Dependencies

Agents Island ships with exactly one package dependency —
[Sparkle](https://github.com/sparkle-project/Sparkle), which powers in-app
updates. It's a deliberate exception: an updater installs executable code, and
that signature-checking path is worth taking from an audited implementation
rather than hand-rolling it.

Everything else is Foundation, SwiftUI, AppKit, and Carbon. PRs that add a
second dependency need a strong justification in the issue first — the app must
stay auditable and fast to launch.

## Privacy is a hard constraint

No telemetry, no analytics, no crash reporting, and nothing about the user's
agents, sessions, prompts, or transcripts may ever leave their machine. That
data is the whole reason people trust this app on a work laptop.

The app makes exactly two kinds of outbound connection, both user-visible and
both disableable:

1. **Update checks** — a daily fetch of the signed appcast from GitHub Releases
   (Settings → About turns it off; Homebrew installs never do it at all)
2. **SSH scans** — only to hosts the user explicitly configured

A PR that adds any other network call will be declined. A PR that sends session
data anywhere will be declined regardless of how it's transported.

## Adding support for a new agent

The most common contribution. You'll want to read `PROJECT.md` first — it
documents each agent's on-disk data sources in detail. In short:

- `Agent.swift` — process detection and brand metadata
- `<Name>Sessions.swift` — a reader for that agent's transcript/session files
- `AgentIconView.swift` — the brand icon

Agents whose CLI writes structured session data locally are supportable; ones
that write nothing readable are not, however popular they are.

## Release process

Merging to `main` cuts the release. You don't set a version number in your PR —
`.github/workflows/release.yml` works it out from the commit subjects, so the
only thing you need to get right is the conventional-commit prefix:

| Commit subject | Result |
| --- | --- |
| `fix: …`, `perf: …` | patch release (0.7.1 → 0.7.2) |
| `feat: …` | minor release (0.7.1 → 0.8.0) |
| `feat!: …`, or `BREAKING CHANGE:` in the body | major release (0.7.1 → 1.0.0) |
| `docs: …`, `chore: …`, `test: …`, `refactor: …`, `ci: …` | no release |

The highest bump in the merge wins, so a PR with one `feat:` and three `fix:`
commits ships a single minor release. Scopes are fine — `fix(detect): …` counts
as a `fix`. A subject that matches nothing above ships nothing, which is the
safe direction to fail: a missed release is one `workflow_dispatch` away, and a
published one can't be recalled.

`scripts/next-version.sh` is the whole decision, and
`scripts/tests/next-version-tests.sh` covers it. To see what the current `main`
would ship without shipping it:

```sh
./scripts/next-version.sh          # prints the version, or nothing
```

### Cutting one by hand

The workflow calls `scripts/release.sh`, and that still works locally when a
maintainer needs to release out of band — it signs, notarizes, staples,
publishes, and bumps the Homebrew cask exactly the same way:

```sh
./scripts/release.sh 0.8.0
```

There is also a **Run workflow** button on the Release action that takes an
optional version, for re-running a release the commit subjects didn't trigger.

### Maintainer setup: the secrets

Only a maintainer needs these, and only once. A fork has none of them, which is
why releases never run on `pull_request`.

| Secret | What it is |
| --- | --- |
| `MACOS_CERT_P12` | Developer ID Application certificate + private key, exported as `.p12` and base64-encoded |
| `MACOS_CERT_PASSWORD` | The password set when exporting that `.p12` |
| `APPLE_ID` | Apple ID for notarization |
| `APPLE_TEAM_ID` | Developer Team ID |
| `APPLE_APP_PASSWORD` | App-specific password from account.apple.com |
| `SPARKLE_PRIVATE_KEY` | The private EdDSA key that signs the appcast |
| `TAP_TOKEN` | A token with `contents: write` on `mustafahalabi/homebrew-tap` |

`scripts/export-release-secrets.sh` prints each value from the local Keychain,
ready to paste. The Sparkle private key in particular is not recoverable if
lost — every existing install would stop receiving updates — so it is worth
having it in a password manager as well as in GitHub.
