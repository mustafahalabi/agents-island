#!/bin/bash
# Cut a signed, notarized release and bump the Homebrew cask.
#   ./scripts/release.sh 0.2.0
#
# One-time setup (needs your Apple Developer account):
#   1. Developer ID certificate — Xcode → Settings → Accounts → your team →
#      Manage Certificates… → + → "Developer ID Application"
#      (or create it at developer.apple.com/account/resources/certificates)
#   2. Notary credentials — create an app-specific password at
#      account.apple.com → Sign-In and Security, then run:
#        xcrun notarytool store-credentials agents-island \
#          --apple-id you@example.com --team-id YOURTEAMID --password xxxx-xxxx-xxxx-xxxx
#
# Without those, set ALLOW_UNSIGNED=1 to ship an ad-hoc-signed release.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: ./scripts/release.sh <version>}"
TAG="v$VERSION"
NOTARY_PROFILE="${NOTARY_PROFILE:-agents-island}"

# ---- Signing prerequisites -------------------------------------------------
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"') || true
HAVE_NOTARY=0
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 && HAVE_NOTARY=1

if [ -z "$SIGN_ID" ] || [ "$HAVE_NOTARY" != 1 ]; then
    if [ "${ALLOW_UNSIGNED:-0}" != 1 ]; then
        echo "Signing setup incomplete:"
        [ -z "$SIGN_ID" ] && echo "  • No 'Developer ID Application' certificate in the keychain (see header of this script, step 1)"
        [ "$HAVE_NOTARY" != 1 ] && echo "  • No notary keychain profile '$NOTARY_PROFILE' (see step 2)"
        echo "Fix the above, or rerun with ALLOW_UNSIGNED=1 to ship unsigned."
        exit 1
    fi
    echo "==> WARNING: shipping ad-hoc signed (users must right-click → Open)"
    SIGN_ID=""
fi

# ---- Build ------------------------------------------------------------------
echo "==> Building $TAG${SIGN_ID:+ signed as $SIGN_ID}"
VERSION="$VERSION" SIGN_ID="$SIGN_ID" ./make-app.sh --no-launch

# ---- Notarize + staple -------------------------------------------------------
if [ -n "$SIGN_ID" ]; then
    echo "==> Notarizing (this usually takes 1–5 minutes)…"
    ditto -c -k --norsrc --noextattr --noacl --keepParent dist/AgentsIsland.app /tmp/AgentsIsland-notarize.zip
    xcrun notarytool submit /tmp/AgentsIsland-notarize.zip \
        --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple dist/AgentsIsland.app
    rm -f /tmp/AgentsIsland-notarize.zip
fi

# ---- Package ------------------------------------------------------------------
# --noextattr/--norsrc: xattrs (e.g. com.apple.provenance, added by macOS
# during signing) become AppleDouble ._ files that CLI unzip extracts as real
# files inside the sealed bundle, breaking Gatekeeper for unzip users.
ditto -c -k --norsrc --noextattr --noacl --keepParent dist/AgentsIsland.app AgentsIsland.zip
shasum -a 256 AgentsIsland.zip > AgentsIsland.zip.sha256
SHA=$(cut -d' ' -f1 < AgentsIsland.zip.sha256)

# Drag-to-install .dmg, built from the app we just notarized+stapled above
# (make-dmg reuses the stapled app, then signs + notarizes + staples the DMG).
DMG="AgentsIsland-${VERSION}.dmg"
VERSION="$VERSION" SIGN_ID="$SIGN_ID" NOTARY_PROFILE="$NOTARY_PROFILE" \
    ./scripts/make-dmg.sh --no-build
shasum -a 256 "$DMG" > "$DMG.sha256"

# ---- Tag + GitHub release -------------------------------------------------------
echo "==> Tagging and releasing $TAG"
git tag "$TAG" 2>/dev/null || echo "    (tag exists, reusing)"
git push origin "$TAG"

if [ -n "$SIGN_ID" ]; then
    NOTES="Signed and notarized. Download **$DMG**, open it, and drag Agents Island to Applications. Or:
\`\`\`sh
brew install --cask mustafahalabi/tap/agents-island
\`\`\`"
else
    NOTES="Unsigned build — open the .dmg, drag to Applications, then right-click → Open the first time. Or:
\`\`\`sh
curl -fsSL https://raw.githubusercontent.com/mustafahalabi/agents-island/main/install.sh | bash
\`\`\`"
fi
gh release create "$TAG" \
    "$DMG" "$DMG.sha256" AgentsIsland.zip AgentsIsland.zip.sha256 \
    --title "Agents Island $TAG" --generate-notes --notes "$NOTES"
rm -f AgentsIsland.zip AgentsIsland.zip.sha256 "$DMG" "$DMG.sha256"

# ---- Bump the Homebrew cask ------------------------------------------------------
echo "==> Bumping cask to $VERSION ($SHA)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git clone --quiet --depth 1 "https://github.com/mustafahalabi/homebrew-tap.git" "$TMP/tap"
CASK="$TMP/tap/Casks/agents-island.rb"
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" \
          -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
git -C "$TMP/tap" commit -qam "agents-island $VERSION"
git -C "$TMP/tap" push -q

echo "==> Done: $TAG released${SIGN_ID:+ (notarized)}, cask bumped."
