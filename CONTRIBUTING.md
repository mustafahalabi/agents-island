# Contributing to Agents Island

Thanks for taking the time to contribute. This is a native macOS SwiftUI app with
no build system beyond SwiftPM, so getting started is short.

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

## No third-party dependencies

Agents Island deliberately ships with zero package dependencies. Everything is
Foundation, SwiftUI, AppKit, and Carbon. PRs that add a dependency need a strong
justification in the issue first — the app reads local files and must stay
auditable and fast to launch.

## Privacy is a hard constraint

Nothing may leave the user's machine. No telemetry, no analytics, no crash
reporting to a remote service, no network calls beyond the SSH scans the user
explicitly configures. A PR that adds an outbound network call will be declined.

## Adding support for a new agent

The most common contribution. You'll want to read `PROJECT.md` first — it
documents each agent's on-disk data sources in detail. In short:

- `Agent.swift` — process detection and brand metadata
- `<Name>Sessions.swift` — a reader for that agent's transcript/session files
- `AgentIconView.swift` — the brand icon

Agents whose CLI writes structured session data locally are supportable; ones
that write nothing readable are not, however popular they are.

## Release process

Releases are cut locally by the maintainer with `scripts/release.sh` — signing
and notarization need a Developer ID certificate that can't live in CI. You don't
need to touch versioning in your PR.
