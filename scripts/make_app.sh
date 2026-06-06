#!/usr/bin/env bash
# Build pappagei and assemble a runnable .app bundle (no Xcode needed).
# Usage: scripts/make_app.sh [debug|release]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
config="${1:-debug}"

swift build -c "$config"
bin=".build/${config}/pappagei"
app="${root}/pappagei.app"

rm -rf "$app"
mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Resources"
cp "$bin" "${app}/Contents/MacOS/pappagei"
if [ -f "${root}/Resources/AppIcon.icns" ]; then
    cp "${root}/Resources/AppIcon.icns" "${app}/Contents/Resources/AppIcon.icns"
fi

cat > "${app}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>pappagei</string>
    <key>CFBundleDisplayName</key><string>pappagei</string>
    <key>CFBundleIdentifier</key><string>tech.pappagei.app</string>
    <key>CFBundleExecutable</key><string>pappagei</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>pappagei liest markierten Text vor.</string>
</dict>
</plist>
PLIST

if ! codesign --force --deep --sign - "$app" >/dev/null 2>&1; then
    echo "warning: ad-hoc codesign skipped"
fi

echo "built ${app}"
