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

# `notarytool submit --wait` exits 0 once processing finishes — including on an
# Invalid verdict — so the status has to be read back rather than inferred from
# the exit code, and the ticket confirmed on disk afterwards.
# notarize_or_die <submit_path> [staple_path]
# An .app is submitted as a zip but stapled on the bundle itself, so the two
# paths differ there; for a DMG they are the same file.
notarize_or_die() {
    local submit="$1" staple="${2:-$1}" out status sub_id
    out=$(xcrun notarytool submit "$submit" \
        --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
    echo "$out"
    status=$(echo "$out" | awk '$1=="status:" {s=$2} END {print s}')
    if [ "$status" != "Accepted" ]; then
        echo "FATAL: notarization of $submit failed (status: ${status:-unknown})." >&2
        sub_id=$(echo "$out" | awk '/^ *id:/ {print $2; exit}')
        [ -n "$sub_id" ] && echo "       xcrun notarytool log $sub_id --keychain-profile $NOTARY_PROFILE" >&2
        exit 1
    fi
    xcrun stapler staple "$staple"
    xcrun stapler validate "$staple" >/dev/null 2>&1 || {
        echo "FATAL: $staple has no stapled ticket after stapling." >&2; exit 1; }
}

# ---- Build the app unless told to reuse the existing bundle ----------------
if [ "${1:-}" != "--no-build" ]; then
    VERSION="$VERSION" SIGN_ID="${SIGN_ID:-}" ./make-app.sh --no-launch
fi
[ -d "$APP" ] || { echo "error: $APP not found — run without --no-build"; exit 1; }

# ---- Notarization requires a Developer ID cert AND a stored notary profile.
#      Signed-but-unnotarized is NOT a milder middle ground: macOS blocks the
#      app and moves it to the Trash, so that combination now aborts unless
#      ALLOW_UNNOTARIZED=1 marks the build as deliberately local-only.
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
    notarize_or_die /tmp/ai-app-notarize.zip "$APP"
    rm -f /tmp/ai-app-notarize.zip
elif [ -n "${SIGN_ID:-}" ]; then
    # A Developer ID signature without a notarization ticket is NOT a milder
    # warning — macOS refuses to launch the app and moves it to the Trash.
    # Silently taking this path is how 0.3.0–0.4.5 shipped broken, so it now
    # requires saying so out loud.
    echo "Signed with Developer ID but notary profile '$NOTARY_PROFILE' is unavailable." >&2
    if [ "${ALLOW_UNNOTARIZED:-0}" != 1 ]; then
        echo "FATAL: refusing to build a signed-but-unnotarized DMG — Gatekeeper" >&2
        echo "       blocks it and macOS deletes the app on first launch." >&2
        echo "       Check 'xcrun notarytool history --keychain-profile $NOTARY_PROFILE'," >&2
        echo "       or set ALLOW_UNNOTARIZED=1 for a deliberate local-only build." >&2
        exit 1
    fi
    echo "==> WARNING: ALLOW_UNNOTARIZED=1 — this DMG must NOT be published."
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
    notarize_or_die "$DMG"
fi

shasum -a 256 "$DMG"
STATE="ad-hoc (right-click → Open)"
[ -n "${SIGN_ID:-}" ] && STATE="Developer ID signed but UNNOTARIZED — Gatekeeper will block this; do not publish"
[ "$HAVE_NOTARY" = 1 ] && STATE="signed & notarized (opens cleanly)"
echo "==> Built $DMG ($(du -h "$DMG" | cut -f1)) — $STATE"
