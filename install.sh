#!/bin/bash
# Agents Island one-line installer:
#   curl -fsSL https://raw.githubusercontent.com/mustafahalabi/agents-island/main/install.sh | bash
#
# Builds from source on your machine (so Gatekeeper has nothing to complain
# about) and installs to /Applications. Needs the Xcode Command Line Tools —
# if you run any coding agent CLI, you almost certainly have them.
set -euo pipefail

REPO="https://github.com/mustafahalabi/agents-island"
BOLD=$(tput bold 2>/dev/null || true); RESET=$(tput sgr0 2>/dev/null || true)

say()  { printf '%s\n' "${BOLD}==>${RESET} $*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Agents Island is a macOS app."

MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$MACOS_MAJOR" -ge 14 ] || fail "macOS 14 (Sonoma) or newer is required."

command -v git >/dev/null 2>&1 || fail "git not found — install the Xcode Command Line Tools: xcode-select --install"
command -v swift >/dev/null 2>&1 || fail "swift not found — install the Xcode Command Line Tools: xcode-select --install"

TMP=$(mktemp -d /tmp/agents-island-install.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

say "Downloading Agents Island…"
git clone --quiet --depth 1 "$REPO" "$TMP/src"

say "Building (release — takes a minute the first time)…"
cd "$TMP/src"
./make-app.sh --no-launch >/dev/null

say "Installing to /Applications…"
rm -rf /Applications/AgentsIsland.app
cp -R dist/AgentsIsland.app /Applications/

say "Launching…"
pkill -x AgentsIsland 2>/dev/null || true
sleep 0.5
open /Applications/AgentsIsland.app

say "Done. Look up at your notch. 🏝️"
echo "    • Settings: hover the island → gear (or the ✦ menu bar item)"
echo "    • Permission approvals: Settings → Integrations → Install"
echo "    • Uninstall: quit from the menu bar, then delete /Applications/AgentsIsland.app"
