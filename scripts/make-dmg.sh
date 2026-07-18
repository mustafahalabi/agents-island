#!/bin/bash
# Package dist/AgentsIsland.app into a drag-to-install .dmg.
#
#   ./scripts/make-dmg.sh                 build app + plain DMG (ad-hoc ok)
#   VERSION=1.0 ./scripts/make-dmg.sh     stamp a version into the filename
#   ./scripts/make-dmg.sh --no-build      package the existing dist/ app as-is
#
# For a no-warning public DMG, set the same signing env the release uses:
#   SIGN_ID="Developer ID Application: …" NOTARY_PROFILE=agents-island \
#     ./scripts/make-dmg.sh
# which signs the app (hardened runtime), notarizes + staples the app AND the
# DMG container, so it opens offline with no Gatekeeper prompt.
#
# Deps: hdiutil only (built into macOS). No create-dmg required.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
APP="dist/AgentsIsland.app"
VOL="Agents Island"
DMG="AgentsIsland-${VERSION}.dmg"

# ---- Build the app unless told to reuse the existing bundle ----------------
if [ "${1:-}" != "--no-build" ]; then
    VERSION="$VERSION" SIGN_ID="${SIGN_ID:-}" ./make-app.sh --no-launch
fi
[ -d "$APP" ] || { echo "error: $APP not found — run without --no-build"; exit 1; }

# ---- Notarization is optional: only if a Developer ID cert AND a stored
#      notary profile are both present. Otherwise we ship signed-but-unnotarized
#      (better than ad-hoc; users still get one Gatekeeper prompt on download).
NOTARY_PROFILE="${NOTARY_PROFILE:-agents-island}"
HAVE_NOTARY=0
if [ -n "${SIGN_ID:-}" ] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    HAVE_NOTARY=1
fi

if [ "$HAVE_NOTARY" = 1 ] && xcrun stapler validate "$APP" >/dev/null 2>&1; then
    echo "==> App is already notarized & stapled — reusing it."
elif [ "$HAVE_NOTARY" = 1 ]; then
    echo "==> Notarizing the app…"
    ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" /tmp/ai-app-notarize.zip
    xcrun notarytool submit /tmp/ai-app-notarize.zip \
        --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f /tmp/ai-app-notarize.zip
elif [ -n "${SIGN_ID:-}" ]; then
    echo "==> Signed with Developer ID but no notary profile '$NOTARY_PROFILE' — skipping notarization."
fi

# ---- Build the DMG ---------------------------------------------------------
rm -f "$DMG"
BG="assets/dmg-background.png"
[ -f "$BG" ] || swift scripts/gen-dmg-background.swift "$BG"

if command -v create-dmg >/dev/null 2>&1; then
    # Styled window: app on the left, an arrow, /Applications on the right.
    # create-dmg makes the drop-link itself — don't pre-stage one.
    create-dmg \
        --volname "$VOL" \
        --background "$BG" \
        --window-pos 200 120 \
        --window-size 660 420 \
        --icon-size 120 \
        --icon "AgentsIsland.app" 165 230 \
        --app-drop-link 495 230 \
        --hide-extension "AgentsIsland.app" \
        --no-internet-enable \
        "$DMG" "$APP"
else
    echo "==> create-dmg not found — building a plain DMG (brew install create-dmg for the styled window)"
    STAGE="$(mktemp -d)/dmg"; mkdir -p "$STAGE"
    ditto "$APP" "$STAGE/AgentsIsland.app"      # ditto preserves the signature
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$VOL" -srcfolder "$STAGE" \
        -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
    rm -rf "$(dirname "$STAGE")"
fi

# ---- Sign the DMG container, and notarize+staple it if we can --------------
if [ -n "${SIGN_ID:-}" ]; then
    codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
fi
if [ "$HAVE_NOTARY" = 1 ]; then
    echo "==> Notarizing the DMG…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

shasum -a 256 "$DMG"
STATE="ad-hoc (right-click → Open)"
[ -n "${SIGN_ID:-}" ] && STATE="Developer ID signed (one Gatekeeper prompt on download)"
[ "$HAVE_NOTARY" = 1 ] && STATE="signed & notarized (opens cleanly)"
echo "==> Built $DMG ($(du -h "$DMG" | cut -f1)) — $STATE"
