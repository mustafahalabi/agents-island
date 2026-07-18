#!/bin/sh
# Build AgentsIsland.app so macOS TCC permissions (Automation, Accessibility)
# attach to a stable bundle identity, then launch it.
#
#   ./make-app.sh              build → dist/AgentsIsland.app → launch
#   ./make-app.sh --install    also copy to /Applications and launch from there
#   ./make-app.sh --no-launch  build only (CI / packaging)
#   NATIVE_ONLY=1 ./make-app.sh   faster build, this Mac's arch only (not releasable)
#   VERSION=1.2.0 ./make-app.sh   stamp a version into Info.plist
#   SIGN_ID="Developer ID Application: …" ./make-app.sh
#                              sign with hardened runtime (notarizable);
#                              default is ad-hoc signing
set -e
cd "$(dirname "$0")"

VERSION="${VERSION:-0.1.0}"

# Sparkle verifies every download against this EdDSA public key. It is public
# by design (the private half lives in the maintainer's Keychain — see
# scripts/release.sh), but a build without it can't verify anything, so the
# app disables in-app updates rather than trusting an unverified download.
# CI and contributor builds legitimately have no key.
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"
if [ -z "$SPARKLE_PUBLIC_KEY" ] && [ -f assets/sparkle-public-key.txt ]; then
    SPARKLE_PUBLIC_KEY=$(tr -d '[:space:]' < assets/sparkle-public-key.txt)
fi
[ -n "$SPARKLE_PUBLIC_KEY" ] || SPARKLE_PUBLIC_KEY="UNSET"

# Served from the latest GitHub release, so the URL is stable across versions
# and needs no separate hosting.
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://github.com/mustafahalabi/agents-island/releases/latest/download/appcast.xml}"

# Universal by default. `swift build` alone produces a binary for the build
# machine's architecture only, which on Apple Silicon means arm64 — and an
# arm64 binary does not run on Intel at all (Rosetta translates x86 to arm, not
# the reverse). Every release up to and including v0.4.7 shipped arm64-only
# while the README promised "Apple Silicon or Intel".
#
# NATIVE_ONLY=1 skips the second slice for a faster local build; never use it
# for a release (scripts/release.sh rejects a thin binary).
if [ "${NATIVE_ONLY:-0}" = 1 ]; then
    swift build -c release
    PRODUCTS=".build/release"
else
    swift build -c release --arch arm64 --arch x86_64
    # Multi-arch builds land somewhere else entirely.
    PRODUCTS=".build/apple/Products/Release"
fi

APP="dist/AgentsIsland.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$PRODUCTS/AgentsIsland" "$APP/Contents/MacOS/AgentsIsland"

# Sparkle.framework — ditto, not cp, so the Versions/Current symlink farm
# survives; a flattened framework fails codesign's bundle-format check.
ditto $PRODUCTS/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"

# SwiftPM links Sparkle as @rpath/... but only bakes in @loader_path, which
# points at Contents/MacOS. Without this the app dies at launch with a dyld
# "Library not loaded" before any of our code runs.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/AgentsIsland" 2>/dev/null || true
# SPM resource bundle (agent brand icons) — Bundle.module finds it in Resources.
cp -R $PRODUCTS/AgentsIsland_AgentsIsland.bundle "$APP/Contents/Resources/" 2>/dev/null || true
cp assets/AppIcon.icns "$APP/Contents/Resources/" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AgentsIsland</string>
    <key>CFBundleIdentifier</key><string>dev.mustafa.agents-island</string>
    <key>CFBundleName</key><string>Agents Island</string>
    <key>CFBundleDisplayName</key><string>Agents Island</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <!-- Sparkle compares CFBundleVersion to decide what is newer, so this
         tracks the real version. It was hardcoded to 1 until auto-update
         landed, which made every release look identical to an updater. -->
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Agents Island sends your replies to agent sessions in your terminal and jumps to their tabs.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Agents Island reads each session's .git/HEAD to show the current branch on its card.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Agents Island reads each session's .git/HEAD to show the current branch on its card.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Agents Island reads each session's .git/HEAD to show the current branch on its card.</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>SUFeedURL</key><string>${SPARKLE_FEED_URL}</string>
    <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
    <!-- Downloading silently in the background is fine; installing is not.
         Replacing a running menu bar app without asking would drop whatever
         the user was watching, so the install step stays user-confirmed. -->
    <key>SUAutomaticallyUpdate</key><false/>
</dict>
</plist>
EOF

# Strip extended attributes before signing: they become AppleDouble (._*)
# entries in zips, and CLI `unzip` extracts those as real files inside the
# sealed bundle — breaking the signature for anyone not using Archive Utility.
xattr -cr "$APP" 2>/dev/null || true

# Code signing must run inside-out: every nested bundle first, the framework
# next, the app last. Sparkle is not a plain dylib — it ships its own helper
# app, an installer daemon and two XPC services, and signing only the outer
# .app leaves those unsigned, which fails notarization.
FW="$APP/Contents/Frameworks/Sparkle.framework"
sparkle_nested() {
    # Versions/B, not the top-level symlinks — codesign rejects symlinked paths.
    echo "$FW/Versions/B/XPCServices/Downloader.xpc" \
         "$FW/Versions/B/XPCServices/Installer.xpc" \
         "$FW/Versions/B/Updater.app" \
         "$FW/Versions/B/Autoupdate"
}

if [ -n "${SIGN_ID:-}" ]; then
    # --preserve-metadata=entitlements: Sparkle's helpers ship with their own
    # entitlements, and replacing them with the app's breaks the installer.
    for nested in $(sparkle_nested); do
        codesign --force --options runtime --timestamp \
            --preserve-metadata=entitlements \
            --sign "$SIGN_ID" "$nested"
    done
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$FW"

    codesign --force --options runtime --timestamp \
        --entitlements assets/entitlements.plist \
        --sign "$SIGN_ID" "$APP"
    # --deep verifies the nested Sparkle helpers too, not just the outer seal.
    codesign --verify --strict --deep "$APP"
else
    for nested in $(sparkle_nested); do
        codesign --force --preserve-metadata=entitlements --sign - "$nested" 2>/dev/null || true
    done
    codesign --force --sign - "$FW" 2>/dev/null || true
    codesign --force --sign - "$APP" 2>/dev/null || true
fi

# --install: put the bundle in /Applications and run it from there.
if [ "$1" = "--install" ]; then
    TARGET="/Applications/AgentsIsland.app"
    rm -rf "$TARGET"
    cp -R "$APP" "$TARGET"
    APP="$TARGET"
fi

# --no-launch: packaging / CI — stop after producing the bundle.
if [ "$1" = "--no-launch" ]; then
    echo "Built $APP (version $VERSION)"
    exit 0
fi

pkill -x AgentsIsland 2>/dev/null || true
sleep 0.5
open "$APP"
echo "Launched $APP"
