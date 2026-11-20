#!/bin/sh
# Builds dist/Microhm.app: the app, the session daemon/CLI (microhm-mux) and the
# background host (microhm-host) side by side in Contents/MacOS, plus SwiftPM resource
# bundles in Contents/Resources. Ad-hoc signed unless SIGN_IDENTITY is set.
#   scripts/build-app.sh            release build
#   CONFIG=debug scripts/build-app.sh
set -eu
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-1.0.0}"
swift build -c "$CONFIG" --product Microhm
swift build -c "$CONFIG" --product microhm-mux
swift build -c "$CONFIG" --product microhm-host
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP=dist/Microhm.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Microhm" "$BIN/microhm-mux" "$BIN/microhm-host" "$APP/Contents/MacOS/"
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
cp ../packaging/icons/micro-harness-manager.icns "$APP/Contents/Resources/Microhm.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Microhm</string>
  <key>CFBundleDisplayName</key><string>Microhm</string>
  <key>CFBundleIdentifier</key><string>io.github.ghosthack.microhm.swift</string>
  <key>CFBundleExecutable</key><string>Microhm</string>
  <key>CFBundleIconFile</key><string>Microhm</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>Microhm serves the phone page on your local network when you turn it on.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign "${SIGN_IDENTITY:--}" "$APP" >/dev/null
echo "$APP"
