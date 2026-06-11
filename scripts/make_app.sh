#!/usr/bin/env bash
# Build pappagei and assemble a runnable .app bundle (no Xcode needed).
# Usage: scripts/make_app.sh [debug|release]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
config="${1:-debug}"

VERSION="0.3.1"
BUILD="$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 1)"

swift build -c "$config"
bin=".build/${config}/pappagei"
app="${root}/pappagei.app"

rm -rf "$app"
mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Resources"
cp "$bin" "${app}/Contents/MacOS/pappagei"
if [ -f "${root}/Resources/AppIcon.icns" ]; then
    cp "${root}/Resources/AppIcon.icns" "${app}/Contents/Resources/AppIcon.icns"
fi

cat > "${app}/Contents/Info.plist" <<PLIST
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
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>pappagei liest markierten Text vor.</string>
    <key>PGBackendPath</key>
    <string>${root}/backend</string>
    <key>NSServices</key>
    <array>
      <dict>
        <key>NSMenuItem</key>
        <dict>
          <key>default</key>
          <string>Vorlesen mit pappagei</string>
        </dict>
        <key>NSMessage</key>
        <string>readSelection</string>
        <key>NSPortName</key>
        <string>pappagei</string>
        <key>NSSendTypes</key>
        <array>
          <string>public.utf8-plain-text</string>
          <string>NSStringPboardType</string>
        </array>
      </dict>
    </array>
</dict>
</plist>
PLIST

if ! codesign --force --deep --sign - "$app" >/dev/null 2>&1; then
    echo "warning: ad-hoc codesign skipped"
fi

# Install into /Applications, replacing any previous version -- that is where
# pappagei is meant to live and run from.
dest="/Applications/pappagei.app"
pkill -f "${dest}/Contents/MacOS/pappagei" 2>/dev/null || true   # stop a running instance so it can be replaced
pkill -f "uvicorn server:app --host 127.0.0.1 --port 8765" 2>/dev/null || true   # and its sidecar, so the port frees
rm -rf "$dest"
ditto "$app" "$dest"
rm -rf "$app"                       # keep the repo tree clean; the app lives in /Applications

# Clear quarantine/xattrs to avoid Gatekeeper app translocation.
xattr -cr "$dest" >/dev/null 2>&1 || true

# Register with LaunchServices so `open` works immediately after building.
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -f "$dest"

echo "installed ${dest}"
