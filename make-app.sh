#!/bin/sh
# Build AgentsIsland.app so macOS TCC permissions (Automation, Accessibility)
# attach to a stable bundle identity, then launch it.
set -e
cd "$(dirname "$0")"

swift build -c release

APP="dist/AgentsIsland.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/AgentsIsland "$APP/Contents/MacOS/AgentsIsland"
# SPM resource bundle (agent brand icons) — Bundle.module finds it in Resources.
cp -R .build/release/AgentsIsland_AgentsIsland.bundle "$APP/Contents/Resources/" 2>/dev/null || true
cp assets/AppIcon.icns "$APP/Contents/Resources/" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AgentsIsland</string>
    <key>CFBundleIdentifier</key><string>dev.mustafa.agents-island</string>
    <key>CFBundleName</key><string>Agents Island</string>
    <key>CFBundleDisplayName</key><string>Agents Island</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Agents Island sends your replies to agent sessions in your terminal and jumps to their tabs.</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" 2>/dev/null || true

# --install: put the bundle in /Applications and run it from there.
if [ "$1" = "--install" ]; then
    TARGET="/Applications/AgentsIsland.app"
    rm -rf "$TARGET"
    cp -R "$APP" "$TARGET"
    APP="$TARGET"
fi

pkill -x AgentsIsland 2>/dev/null || true
sleep 0.5
open "$APP"
echo "Launched $APP"
