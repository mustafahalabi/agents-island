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

# Gatekeeper gate. A Developer ID signature is NOT enough — without a stapled
# ticket macOS quarantines the app on first launch and users watch it vanish
# from /Applications. Releases 0.3.0–0.4.5 shipped exactly that way, so nothing
# gets uploaded until the artifact users actually download passes spctl.
verify_notarized() {
    local target="$1" label="$2"
    # spctl assessment type depends on the artifact: an .app is judged as an
    # executable, a .dmg as a document you open. Using -t exec on a disk image
    # reports "does not seem to be an app" for a perfectly good DMG.
    local -a assess
    case "$target" in
        *.dmg) assess=(-a -t open --context context:primary-signature) ;;
        *)     assess=(-a -t exec) ;;
    esac
    echo "==> Verifying $label"
    if ! xcrun stapler validate "$target" >/dev/null 2>&1; then
        echo "FATAL: $label has no stapled notarization ticket." >&2
        echo "       Gatekeeper will block it. Refusing to publish." >&2
        exit 1
    fi
    if ! spctl "${assess[@]}" "$target" >/dev/null 2>&1; then
        echo "FATAL: $label is rejected by Gatekeeper:" >&2
        spctl "${assess[@]}" -vv "$target" 2>&1 | sed 's/^/       /' >&2
        exit 1
    fi
    echo "    ✓ $label: notarized, stapled, Gatekeeper-accepted"
}

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

# ---- Tap access (checked up front) -----------------------------------------
# Clone and dry-run the push *before* anything is published. The tap bump used
# to run last, so a credential problem surfaced only after the release was
# already public — leaving releases shipping while the cask silently rotted.
KEEP_TAP=0
TAPTMP=$(mktemp -d)
trap '[ "$KEEP_TAP" = 1 ] || rm -rf "$TAPTMP"' EXIT
if [ -n "$SIGN_ID" ]; then
    echo "==> Checking Homebrew tap push access"
    git clone --quiet --depth 1 "https://github.com/mustafahalabi/homebrew-tap.git" "$TAPTMP/tap"
    if ! git -C "$TAPTMP/tap" push --dry-run -q 2>/dev/null; then
        echo "FATAL: no push access to mustafahalabi/homebrew-tap." >&2
        echo "       Fix credentials first — otherwise the release ships and the" >&2
        echo "       cask stays behind, which is how 0.3.0–0.4.5 got stranded." >&2
        exit 1
    fi
    echo "    ✓ tap writable"
fi

# ---- Build ------------------------------------------------------------------
echo "==> Building $TAG${SIGN_ID:+ signed as $SIGN_ID}"
VERSION="$VERSION" SIGN_ID="$SIGN_ID" ./make-app.sh --no-launch

# ---- Notarize + staple -------------------------------------------------------
if [ -n "$SIGN_ID" ]; then
    echo "==> Notarizing (this usually takes 1–5 minutes)…"
    ditto -c -k --norsrc --noextattr --noacl --keepParent dist/AgentsIsland.app /tmp/AgentsIsland-notarize.zip
    # `notarytool submit --wait` exits 0 once processing *finishes* — including
    # when the verdict is Invalid — so the status has to be read back, not
    # inferred from the exit code.
    SUBMIT_OUT=$(xcrun notarytool submit /tmp/AgentsIsland-notarize.zip \
        --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
    echo "$SUBMIT_OUT"
    # Match only the final summary's "  status: X" — the progress lines read
    # "Current status: In Progress", where $2 is "status:" rather than a verdict.
    STATUS=$(echo "$SUBMIT_OUT" | awk '$1=="status:" {s=$2} END {print s}')
    if [ "$STATUS" != "Accepted" ]; then
        echo "FATAL: notarization did not succeed (status: ${STATUS:-unknown})." >&2
        SUB_ID=$(echo "$SUBMIT_OUT" | awk '/^ *id:/ {print $2; exit}')
        [ -n "$SUB_ID" ] && echo "       xcrun notarytool log $SUB_ID --keychain-profile $NOTARY_PROFILE" >&2
        exit 1
    fi
    xcrun stapler staple dist/AgentsIsland.app
    rm -f /tmp/AgentsIsland-notarize.zip
    verify_notarized dist/AgentsIsland.app "built app"
fi

# ---- Package ------------------------------------------------------------------
# --noextattr/--norsrc: xattrs (e.g. com.apple.provenance, added by macOS
# during signing) become AppleDouble ._ files that CLI unzip extracts as real
# files inside the sealed bundle, breaking Gatekeeper for unzip users.
ditto -c -k --norsrc --noextattr --noacl --keepParent dist/AgentsIsland.app AgentsIsland.zip
shasum -a 256 AgentsIsland.zip > AgentsIsland.zip.sha256
SHA=$(cut -d' ' -f1 < AgentsIsland.zip.sha256)

# Round-trip the zip through the same `unzip` users run. Verifying dist/ only
# proves the app was fine *before* packaging; the ticket and the seal have to
# survive the archive, and that is what actually reaches people.
if [ -n "$SIGN_ID" ]; then
    ZIPCHECK=$(mktemp -d)
    unzip -q AgentsIsland.zip -d "$ZIPCHECK"
    verify_notarized "$ZIPCHECK/AgentsIsland.app" "packaged AgentsIsland.zip"
    rm -rf "$ZIPCHECK"
fi

# Drag-to-install .dmg, built from the app we just notarized+stapled above
# (make-dmg reuses the stapled app, then signs + notarizes + staples the DMG).
DMG="AgentsIsland-${VERSION}.dmg"
VERSION="$VERSION" SIGN_ID="$SIGN_ID" NOTARY_PROFILE="$NOTARY_PROFILE" \
    ./scripts/make-dmg.sh --no-build
shasum -a 256 "$DMG" > "$DMG.sha256"
if [ -n "$SIGN_ID" ]; then verify_notarized "$DMG" "$DMG"; fi

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
# Only ever point the cask at a build that cleared verify_notarized above —
# an unsigned build in the tap is worse than a stale one, because `brew install`
# then hands every user an app macOS deletes on first launch.
if [ -z "$SIGN_ID" ]; then
    echo "==> Skipping cask bump: unsigned build stays out of the tap."
    echo "==> Done: $TAG released (UNSIGNED), cask left at its previous version."
    exit 0
fi

echo "==> Bumping cask to $VERSION ($SHA)"
CASK="$TAPTMP/tap/Casks/agents-island.rb"
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" \
          -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
git -C "$TAPTMP/tap" commit -qam "agents-island $VERSION"
if ! git -C "$TAPTMP/tap" push -q; then
    echo "" >&2
    echo "WARNING: $TAG is published but the cask bump FAILED to push." >&2
    echo "         brew users stay on the previous version until this lands:" >&2
    echo "           cd $TAPTMP/tap && git push" >&2
    echo "         (that checkout is kept on purpose — do not delete it yet)" >&2
    KEEP_TAP=1
    exit 1
fi

echo "==> Done: $TAG released (notarized), cask bumped to $VERSION."
