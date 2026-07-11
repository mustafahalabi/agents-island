#!/bin/bash
# Cut a release: tag → CI builds the zip → bump the Homebrew cask.
#   ./scripts/release.sh 0.2.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: ./scripts/release.sh <version>}"
TAG="v$VERSION"
TAP_REPO="git@github.com:mustafahalabi/homebrew-tap.git"

echo "==> Tagging $TAG"
git tag "$TAG"
git push origin "$TAG"

echo "==> Waiting for the release workflow…"
sleep 15
gh run watch --repo mustafahalabi/agents-island \
  "$(gh run list --repo mustafahalabi/agents-island --limit 1 --json databaseId --jq '.[0].databaseId')" \
  --exit-status

echo "==> Fetching checksum"
SHA=$(curl -fsSL "https://github.com/mustafahalabi/agents-island/releases/download/$TAG/AgentsIsland.zip.sha256" | cut -d' ' -f1)

echo "==> Bumping cask to $VERSION ($SHA)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git clone --quiet --depth 1 "$TAP_REPO" "$TMP/tap" 2>/dev/null \
  || git clone --quiet --depth 1 "https://github.com/mustafahalabi/homebrew-tap.git" "$TMP/tap"
CASK="$TMP/tap/Casks/agents-island.rb"
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" \
          -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
git -C "$TMP/tap" commit -qam "agents-island $VERSION"
git -C "$TMP/tap" push -q

echo "==> Done: $TAG released, cask bumped."
