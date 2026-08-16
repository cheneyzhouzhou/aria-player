#!/bin/bash
# Rebuilds and reinstalls Aria on a connected iPhone.
#
# A free Apple developer account signs apps with a 7-day provisioning profile,
# so the installed app stops launching after a week. Rebuilding issues a fresh
# profile — nothing else needs redoing, and the app's Documents folder (your
# music) survives a reinstall untouched.
#
#   ./renew-ios.sh           rebuild, reinstall, relaunch
#   ./renew-ios.sh --auto    for scheduled runs: no relaunch, and skips while
#                            Aria is playing so it never interrupts you
#
# Configuration, in order of precedence:
#   DEVICE_UDID=... ./renew-ios.sh     environment variable
#   echo "<udid>" > .device-udid       untracked file beside this script
#
# Find your device identifier with:  xcrun devicectl list devices
set -euo pipefail

cd "$(dirname "$0")"

BUNDLE="${BUNDLE_ID:-com.example.aria}"
APP=build/dd-device/Build/Products/Debug-iphoneos/Aria.app
AUTO="${1:-}"

if [ -z "${DEVICE_UDID:-}" ] && [ -f .device-udid ]; then
    DEVICE_UDID="$(tr -d '[:space:]' < .device-udid)"
fi
if [ -z "${DEVICE_UDID:-}" ]; then
    echo "No device configured. Either:"
    echo "  export DEVICE_UDID=<udid>"
    echo "  echo <udid> > .device-udid"
    echo
    echo "List devices with: xcrun devicectl list devices"
    exit 1
fi

stamp() { date "+%Y-%m-%d %H:%M:%S"; }

if ! xcrun devicectl list devices 2>/dev/null | grep -q "$DEVICE_UDID"; then
    echo "$(stamp)  iPhone not reachable — will try again next run."
    [ "$AUTO" = "--auto" ] && exit 0
    echo "Connect it by cable, or put it on this Wi-Fi and unlock it."
    exit 1
fi

# Reinstalling terminates the running app, so an unattended run backs off
# rather than cutting off whatever is playing.
if [ "$AUTO" = "--auto" ]; then
    if xcrun devicectl device info processes --device "$DEVICE_UDID" 2>/dev/null \
        | grep -q "/Aria.app/Aria"; then
        echo "$(stamp)  Aria is in use — skipping, will retry next run."
        exit 0
    fi
fi

echo "$(stamp)  Building (issues a fresh 7-day profile)"
xcodebuild -project Aria.xcodeproj -scheme Aria \
    -destination 'generic/platform=iOS' \
    -derivedDataPath build/dd-device \
    -allowProvisioningUpdates build >/dev/null

echo "$(stamp)  Installing"
xcrun devicectl device install app --device "$DEVICE_UDID" "$APP" >/dev/null

if [ "$AUTO" != "--auto" ]; then
    echo "$(stamp)  Launching"
    xcrun devicectl device process launch --terminate-existing --device "$DEVICE_UDID" "$BUNDLE" >/dev/null
fi

echo "$(stamp)  Aria renewed — good for another 7 days."
