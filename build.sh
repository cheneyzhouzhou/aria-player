#!/bin/bash
# Builds Aria.app. Pass --run to launch it afterwards.
set -euo pipefail

cd "$(dirname "$0")"
APP="build/Aria.app"

echo "==> Compiling"
# SwiftPM spawns its own sandbox; when this script is itself run inside one
# (WorkBuddy agent shell) manifest loading fails with "sandbox_apply: Operation
# not permitted". Disabling it is harmless for a normal terminal build.
swift build -c release --disable-sandbox -Xswiftc -Xfrontend -Xswiftc -disable-sandbox

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Aria "$APP/Contents/MacOS/Aria"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The icon is generated once and reused on later builds.
if [ ! -f Resources/AppIcon.icns ]; then
    echo "==> Generating icon"
    swift Tools/MakeIcon.swift Resources/AppIcon.png >/dev/null
    ICONSET=$(mktemp -d)/AppIcon.iconset
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
    rm -rf "$ICONSET"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: enough for macOS to grant the app a stable TCC identity.
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null

echo "==> Built $APP"

if [ "${1:-}" = "--run" ]; then
    open "$APP"
fi
