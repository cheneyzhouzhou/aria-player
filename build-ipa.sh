#!/bin/bash
# Builds an unsigned Aria.ipa for a physical iPhone.
#
# The IPA is not signed: Sideloadly, AltStore or TrollStore re-sign it with
# your own Apple ID at install time. That also means a free Apple ID gives you
# 7 days per signing, and 3 apps at a time.
#
# Requires full Xcode — the Command Line Tools alone have no iOS SDK.
#
#   ./build-ipa.sh              build build/Aria.ipa
#   ./build-ipa.sh --sign TEAM  build a device-signed IPA with your team ID
set -euo pipefail

cd "$(dirname "$0")"

if ! xcodebuild -version >/dev/null 2>&1; then
    echo "xcodebuild not found. Aria's iOS target needs full Xcode:" >&2
    echo "  1. Install Xcode from the Mac App Store (about 3 GB, needs ~40 GB free)." >&2
    echo "  2. sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    echo "  3. sudo xcodebuild -license accept" >&2
    exit 1
fi

SCHEME="Aria"
PROJECT="Aria.xcodeproj"
DERIVED="build/dd-device"
OUT="build/Aria.ipa"
TEAM="${2:-}"

echo "==> Building for device"
if [ -n "$TEAM" ]; then
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
        -sdk iphoneos -derivedDataPath "$DERIVED" \
        DEVELOPMENT_TEAM="$TEAM" -allowProvisioningUpdates build
else
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
        -sdk iphoneos -derivedDataPath "$DERIVED" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY="" build
fi

APP="$DERIVED/Build/Products/Release-iphoneos/Aria.app"
[ -d "$APP" ] || { echo "No app produced at $APP" >&2; exit 1; }

# An unsigned device build keeps its arm64 binary; if Xcode stripped it,
# re-sign ad-hoc so the bundle still has a valid code directory.
if [ -z "$TEAM" ]; then
    echo "==> Ad-hoc signing the bundle"
    codesign --force --sign - --timestamp=none "$APP" 2>/dev/null || true
fi

echo "==> Packaging $OUT"
rm -rf build/Payload "$OUT"
mkdir -p build/Payload
cp -R "$APP" build/Payload/
( cd build && zip -qry Aria.ipa Payload )
rm -rf build/Payload

echo "==> Done: $OUT ($(du -h "$OUT" | cut -f1))"
echo
echo "Install with Sideloadly (sideloadly.io) or AltStore:"
echo "  1. Connect the iPhone by cable, trust this Mac."
echo "  2. Drop $OUT into Sideloadly, enter your Apple ID."
echo "  3. On the phone: Settings > General > VPN & Device Management > trust the developer."
echo
echo "A free Apple ID signature expires after 7 days; re-run Sideloadly to renew."
