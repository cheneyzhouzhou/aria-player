#!/bin/bash
# Builds Aria.app for the iOS Simulator and installs it on the booted device.
# No Xcode project needed — the simulator accepts an ad-hoc bundle.
# A real device needs an Xcode project for provisioning; see IOS-SETUP.md.
set -euo pipefail

cd "$(dirname "$0")"
APP="build/ios/Aria.app"
BUNDLE_ID="com.example.aria"
TARGET="arm64-apple-ios17.0-simulator"

echo "==> Compiling for iOS Simulator"
rm -rf "$APP"
mkdir -p "$APP"
xcrun --sdk iphonesimulator swiftc -O \
    -target "$TARGET" \
    -parse-as-library \
    -o "$APP/Aria" \
    $(find Sources/Aria -name "*.swift")

echo "==> Writing Info.plist"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key><string>Aria</string>
    <key>CFBundleName</key><string>Aria</string>
    <key>CFBundleExecutable</key><string>Aria</string>
    <key>CFBundleIdentifier</key><string>com.example.aria</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>MinimumOSVersion</key><string>17.0</string>
    <key>UIDeviceFamily</key><array><integer>1</integer></array>
    <key>UILaunchScreen</key><dict/>
    <key>UISupportedInterfaceOrientations</key>
    <array><string>UIInterfaceOrientationPortrait</string></array>
    <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>

    <!-- Aria's Documents folder in Finder, and in the Files app. -->
    <key>UIFileSharingEnabled</key><true/>
    <key>LSSupportsOpeningDocumentsInPlace</key><true/>
    <!-- Playback survives lock and backgrounding. -->
    <key>UIBackgroundModes</key><array><string>audio</string></array>
</dict>
</plist>
PLIST

echo "==> Installing on booted simulator"
xcrun simctl install booted "$APP"

echo "==> Built and installed $APP"
if [ "${1:-}" = "--run" ]; then
    xcrun simctl launch booted "$BUNDLE_ID" >/dev/null
    echo "==> Launched"
fi
