#!/bin/bash
# Builds Focus.app into ./build and (optionally) installs it to /Applications.
set -euo pipefail

cd "$(dirname "$0")"
APP="build/Focus.app"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Focus</string>
    <key>CFBundleDisplayName</key>     <string>Focus</string>
    <key>CFBundleExecutable</key>      <string>Focus</string>
    <key>CFBundleIdentifier</key>      <string>local.focus.menubar</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>12.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Focus reads the address of your front browser tab so you can mark individual websites as time wasted. The address is never stored or sent anywhere — only the site name of sites you mark yourself.</string>
</dict>
</plist>
PLIST

echo "Compiling…"
swiftc -O \
    -target "$(uname -m)-apple-macos12.0" \
    -framework Cocoa -framework ServiceManagement \
    -o "$APP/Contents/MacOS/Focus" \
    Sources/main.swift

# Ad-hoc signature: required for the login-item API and for a stable identity.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "(codesign skipped)"

echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    pkill -f "/Focus" 2>/dev/null || true
    rm -rf /Applications/Focus.app
    cp -R "$APP" /Applications/
    open /Applications/Focus.app
    echo "Installed and launched from /Applications/Focus.app"
else
    echo "Run it with:  open $APP"
    echo "Or install:   ./build.sh --install"
fi
