#!/bin/bash
# Builds both macOS flavours of Aria:
#
#   build/Aria.app                          arm64 only (Apple Silicon)
#   build/Aria-universal.app                arm64 + x86_64 (Intel + Apple Silicon)
#   build/Aria-v<N>-macOS.zip               arm64-only, ready to ship
#   build/Aria-v<N>-macOS-universal.zip     universal, ready to ship
#
# The version comes from VERSION (or ARIA_VERSION, which CI sets from its tag)
# and is NOT bumped here — build-ipa.sh owns the bump. Run this before
# build-ipa.sh so both platforms carry the same number.
#
# Pass --run to launch the arm64 build afterwards.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"

APP="build/Aria.app"
UNIVERSAL="build/Aria-universal.app"
ARM_SCRATCH="build/.swiftpm-arm64"
X86_SCRATCH="build/.swiftpm-x86_64"
FAT="build/Aria-fat"

# CI passes a tag like "v30"; keep only digits so both `30` and `v30` work.
VERSION="${ARIA_VERSION:-$(cat VERSION 2>/dev/null || echo 1)}"
VERSION="$(printf '%s' "$VERSION" | tr -dc '0-9')"
[ -n "$VERSION" ] || VERSION=1
ARM_ZIP="build/Aria-v${VERSION}-macOS.zip"
UNIVERSAL_ZIP="build/Aria-v${VERSION}-macOS-universal.zip"

# SwiftPM spawns its own sandbox; when this script is itself run inside one
# (WorkBuddy agent shell, CI) manifest loading fails. The extra frontend flag
# is for SwiftUI's @State macro, which expands through another sandboxed helper.
SWIFT_FLAGS="--disable-sandbox -Xswiftc -Xfrontend -Xswiftc -disable-sandbox"

echo "==> Compiling arm64 (Apple Silicon)"
# shellcheck disable=SC2086
swift build -c release --arch arm64 --scratch-path "$ARM_SCRATCH" $SWIFT_FLAGS

echo "==> Compiling x86_64 (Intel)"
# shellcheck disable=SC2086
swift build -c release --arch x86_64 --scratch-path "$X86_SCRATCH" $SWIFT_FLAGS

ARM_BIN="$ARM_SCRATCH/out/Products/Release/Aria"
X86_BIN="$X86_SCRATCH/out/Products/Release/Aria"
[ -f "$ARM_BIN" ] || { echo "arm64 binary missing at $ARM_BIN" >&2; exit 1; }
[ -f "$X86_BIN" ] || { echo "x86_64 binary missing at $X86_BIN" >&2; exit 1; }

echo "==> Combining into a universal binary"
lipo -create -output "$FAT" "$ARM_BIN" "$X86_BIN"
lipo -info "$FAT"

# The icon is generated once and reused on later builds (it is gitignored).
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

assemble() {
    local dest="$1" binary="$2"
    rm -rf "$dest"
    mkdir -p "$dest/Contents/MacOS" "$dest/Contents/Resources"
    cp "$binary" "$dest/Contents/MacOS/Aria"
    cp Resources/Info.plist "$dest/Contents/Info.plist"
    cp Resources/AppIcon.icns "$dest/Contents/Resources/AppIcon.icns"
    # Ad-hoc signature: enough for macOS to grant the app a stable TCC identity.
    codesign --force --sign - --timestamp=none "$dest" 2>/dev/null || true
}

echo "==> Assembling bundles"
assemble "$APP" "$ARM_BIN"
assemble "$UNIVERSAL" "$FAT"

echo "==> Packaging $ARM_ZIP and $UNIVERSAL_ZIP"
rm -f "$ARM_ZIP" "$UNIVERSAL_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARM_ZIP"
# Ship the universal bundle under the same clean "Aria.app" name inside the zip.
STAGE=$(mktemp -d)
cp -R "$UNIVERSAL" "$STAGE/Aria.app"
codesign --force --sign - --timestamp=none "$STAGE/Aria.app" 2>/dev/null || true
( cd "$STAGE" && ditto -c -k --sequesterRsrc --keepParent Aria.app "$ROOT/$UNIVERSAL_ZIP" )
rm -rf "$STAGE"

echo "==> Built:"
echo "    $APP  ($(lipo -archs "$APP/Contents/MacOS/Aria"))"
echo "    $UNIVERSAL  ($(lipo -archs "$UNIVERSAL/Contents/MacOS/Aria"))"
echo "    $ARM_ZIP ($(du -h "$ARM_ZIP" | cut -f1))"
echo "    $UNIVERSAL_ZIP ($(du -h "$UNIVERSAL_ZIP" | cut -f1))"

if [ "${1:-}" = "--run" ]; then
    open "$APP"
fi
