#!/bin/sh
# Build AgentsIsland.app so macOS TCC permissions (Automation, Accessibility)
# attach to a stable bundle identity, then launch it.
#
#   ./make-app.sh              build → dist/AgentsIsland.app → launch
#   ./make-app.sh --install    also copy to /Applications and launch from there
#   ./make-app.sh --no-launch  build only (CI / packaging)
#   VERSION=1.2.0 ./make-app.sh   stamp a version into Info.plist
#   SIGN_ID="Developer ID Application: …" ./make-app.sh
#                              sign with hardened runtime (notarizable);
#                              default is ad-hoc signing
set -e
cd "$(dirname "$0")"

VERSION="${VERSION:-0.1.0}"

swift build -c release

APP="dist/AgentsIsland.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/AgentsIsland "$APP/Contents/MacOS/AgentsIsland"
# SPM resource bundle (agent brand icons) — Bundle.module finds it in Resources.
cp -R .build/release/AgentsIsland_AgentsIsland.bundle "$APP/Contents/Resources/" 2>/dev/null || true
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
    <key>CFBundleVersion</key><string>1</string>
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
</dict>
</plist>
EOF

if [ -n "${SIGN_ID:-}" ]; then
    codesign --force --options runtime --timestamp \
        --entitlements assets/entitlements.plist \
        --sign "$SIGN_ID" "$APP"
    codesign --verify --strict "$APP"
else
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
