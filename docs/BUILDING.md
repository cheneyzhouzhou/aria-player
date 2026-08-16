# Building and installing Aria

Two targets share one source tree: a macOS app built with Swift Package Manager, and an iOS
app built with the Xcode project. Both compile the same files from `Sources/Aria`.

---

## macOS

Command Line Tools are enough — you don't need full Xcode.

```bash
./build.sh          # builds build/Aria.app
./build.sh --run    # …and opens it
```

The script compiles with SwiftPM, assembles the `.app` bundle, generates an icon on first
run, and ad-hoc signs it. Aria scans `~/Music` by default; change that in Settings.

If you have Xcode installed but builds fail with a licence error:

```bash
sudo xcodebuild -license accept
```

---

## iOS

Needs full Xcode (from the Mac App Store — roughly a 3 GB download, and keep ~40 GB free
while it installs). Afterwards, point the tools at it:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

### Simulator

No signing required — the simulator accepts an unsigned bundle:

```bash
xcrun simctl boot "iPhone 17"     # any booted simulator
./build-ios-sim.sh --run
```

To give it music, copy files into the app's container:

```bash
python3 Tools/make-demo-library.py /tmp/aria-demo
cp -R /tmp/aria-demo/* "$(xcrun simctl get_app_container booted com.example.aria data)/Documents/"
```

### A physical iPhone

This is where most of the friction is. Each step below is a real gate — skipping one
produces an error that looks like something else entirely.

#### 1. Add your Apple ID to Xcode

**Xcode ▸ Settings ▸ Accounts ▸ + ▸ Apple ID.**

This is *not* the same as signing into macOS System Settings. Signing in there does nothing
for code signing, and it's the single most common reason nothing seems to happen.

*Worked when:* your email appears in the list with "Personal Team" under it.

#### 2. Choose a Team

Open `Aria.xcodeproj`, select the **Aria** target ▸ **Signing & Capabilities** ▸ **Team**.

The development certificate is created at this moment, not when you sign in. Until you pick
a team, `security find-identity -v -p codesigning` reports zero identities. If the dropdown
is empty, quit Xcode fully and reopen — it often doesn't refresh the team list otherwise.

While you're here, change **Bundle Identifier** from `com.example.aria` to something of your
own, e.g. `com.yourname.aria`.

#### 3. Pair the device

Connect the iPhone, unlock it, and tap **Trust**. If Xcode still shows *"pairing is in
progress"*:

```bash
xcrun devicectl manage pair --device <udid>
xcrun devicectl list devices          # find the udid
```

#### 4. Enable Developer Mode on the phone

**Settings ▸ Privacy & Security ▸ Developer Mode ▸ on**, then **restart the phone**.

The toggle does nothing until the device reboots — iOS arms the change at boot. After
restarting and unlocking, a prompt appears: tap **Turn On** and enter your passcode. If you
dismiss that prompt, Developer Mode stays off.

The option only appears in Settings *after* a Mac has attempted to install a developer app,
so if you can't find it, try installing once first.

Check the phone's own view of it:

```bash
xcrun devicectl device info details --device <udid> | grep developerModeStatus
```

#### 5. Build and install

From Xcode: pick your iPhone in the device menu and press ⌘R.

Or from the command line:

```bash
xcodebuild -project Aria.xcodeproj -scheme Aria \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/dd-device \
  -allowProvisioningUpdates build

xcrun devicectl device install app --device <udid> \
  build/dd-device/Build/Products/Debug-iphoneos/Aria.app
```

#### 6. Trust the certificate

First launch will be refused. On the phone: **Settings ▸ General ▸ VPN & Device Management
▸ your Apple ID ▸ Trust**. The phone needs a network connection to verify.

---

## Getting music onto the iPhone

**Finder** — plug the phone in, then **Finder ▸ your iPhone ▸ Files ▸ Aria**, and drag
folders in. Subfolders are fine; the scanner walks the whole tree.

**Command line** — faster and scriptable:

```bash
xcrun devicectl device copy to --device <udid> \
  --domain-type appDataContainer --domain-identifier com.example.aria \
  --source "/path/to/Album" --destination "Documents/Album"
```

> **The destination must name the folder itself.** `copy to` *replaces* the destination
> rather than copying into it. A bare `--destination "Documents/"` overwrites the entire
> Documents folder — and with a single file as the source, it replaces the directory with
> that file, leaving the app nothing to scan.

Verify what actually landed rather than trusting the command's output, which prints the
destination on success either way:

```bash
xcrun devicectl device info files --device <udid> \
  --domain-type appDataContainer --domain-identifier com.example.aria \
  --username mobile | grep -c '\.flac'
```

`Library/Application Support/Aria/library.json` is the app's parsed-track cache. Two bytes
means the scan found nothing; tens of KB means it worked.

---

## Keeping a free-account build alive

A free Apple ID signs apps with a **7-day** provisioning profile. After that the app stays
installed — with your music intact — but refuses to launch. Rebuilding issues a fresh
profile:

```bash
echo "<your-device-udid>" > .device-udid    # once
./renew-ios.sh
```

A paid Apple Developer Program membership ($99/year) extends the profile to a year.

### Automatic renewal

`renew-ios.sh --auto` skips when the phone is unreachable *or* while Aria is playing, so it
never interrupts you. Wire it to a launch agent:

```xml
<!-- ~/Library/LaunchAgents/com.example.aria.renew.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.example.aria.renew</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/aria-player/renew-ios.sh</string>
        <string>--auto</string>
    </array>
    <key>WorkingDirectory</key><string>/path/to/aria-player</string>
    <key>StartCalendarInterval</key>
    <dict><key>Hour</key><integer>4</integer><key>Minute</key><integer>0</integer></dict>
    <key>StandardOutPath</key><string>/path/to/aria-player/build/renew.log</string>
    <key>StandardErrorPath</key><string>/path/to/aria-player/build/renew.log</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.example.aria.renew.plist
launchctl start com.example.aria.renew    # test it now
```

> **Do not keep the project in `~/Downloads`.** That folder carries a quarantine flag and a
> TCC access list, and macOS refuses to let a launchd job read or execute anything inside
> it — the job dies with `Operation not permitted` before your script runs. It looks like a
> missing `+x` bit and isn't. Routing through `/bin/bash`, or via a launcher stored
> elsewhere, doesn't help either: the *read* of the script is what's denied. Keep the
> project somewhere like `~/Developer`.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| `Signing for "Aria" requires a development team` | No Team selected — step 2 |
| `0 valid identities found` | Apple ID added to System Settings, not Xcode ▸ Accounts |
| `The device must be paired` | Run `xcrun devicectl manage pair` |
| `Developer Mode is disabled` | Toggle it **and restart the phone** |
| `profile has not been explicitly trusted` | Trust the certificate on the phone — step 6 |
| App stops opening after a week | Free-account profile expired; run `./renew-ios.sh` |
| Empty library on the simulator | Each simulator has its own container; copy music to the one you're running |
| `missing required module 'SwiftShims'` | Stale SwiftPM cache after moving the project — `rm -rf .build` |
| launchd job exits 126 | Project is inside `~/Downloads`; move it |
