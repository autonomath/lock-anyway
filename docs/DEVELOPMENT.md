# Development Guide

## Requirements

- macOS
- Swift 6.2.3 or newer
- Developer ID Application certificate for stable Accessibility trust across rebuilds
- Developer ID Installer certificate for signed packages

The project is a Swift Package and does not require `xcodebuild`.

## Build

```sh
scripts/build-app.sh
```

Output:

```text
.build/release/Lock Anyway.app
```

The script signs with `Developer ID Application` when available. Without a Developer ID identity, it falls back to ad-hoc signing.

## Test

```sh
swift run IdleLockSelfTest
```

This project uses the included `IdleLockSelfTest` executable instead of `swift test`.

## Reload After App Changes

```sh
scripts/reload-app.sh
```

The reload script:

- Builds the release app.
- Stops the running LaunchAgent/app.
- Installs to `/Applications/Lock Anyway.app`.
- Rewrites `~/Library/LaunchAgents/com.user.idle-lock.plist`.
- Starts the LaunchAgent again.

Verify the active path:

```sh
for pid in $(pgrep -x IdleLock); do ps -p "$pid" -o pid=,command=; done
```

Expected path:

```text
/Applications/Lock Anyway.app/Contents/MacOS/IdleLock
```

## Package

```sh
scripts/package-app.sh
```

Output:

```text
dist/LockAnyway-1.1.0.pkg
```

Check package signing:

```sh
pkgutil --check-signature dist/LockAnyway-1.1.0.pkg
```

## DMG

```sh
scripts/package-dmg.sh
```

Output:

```text
dist/LockAnyway.dmg
```

The DMG flow is drag-to-Applications. The app refuses to run from `/Volumes/...` so users do not accidentally bind Accessibility permission or Start at Login to the mounted image.

For a notarized release DMG, reuse any `notarytool` profile for the same Apple Developer team:

```sh
scripts/package-dmg.sh \
  --notarize \
  --notary-profile TilePilot \
  --notary-keychain "$HOME/Library/Keychains/login.keychain-db"
```

The release DMG script follows the same flow as TilePilot:

- build the release `.app`
- sign the app with `Developer ID Application`, hardened runtime, and timestamp
- create a drag-to-Applications staging folder
- build a read/write DMG with `hdiutil`
- apply Finder icon layout
- convert to compressed `UDZO`
- sign the final DMG
- optionally submit the DMG to Apple notarization, staple the ticket, and run Gatekeeper validation

## Manual Verification

1. Run `swift run IdleLockSelfTest`.
2. Run `scripts/reload-app.sh`.
3. Set custom delay `30s` and countdown warning `10 sec`.
4. Use `Preview Popup` in Preferences to check the popup without waiting for idle time.
5. Verify overlay visibility over fullscreen video and all Spaces.
6. Verify mouse/key activity and clicking the dimmed background cancel the countdown.
7. Verify moving the cursor to a screen edge hides the popup immediately instead of leaving the postponed message visible.
8. Verify buttons and number keys add time:
   - `1`: 15 minutes
   - `2`: 30 minutes
   - `3`: 1 hour
   - `4`: 2 hours
9. Verify `Disable Locking` pauses until resumed.
10. Verify countdown reaches lock.
11. Verify RustDesk remains connected while the local Mac locks.

## Do Not Create Duplicate App Copies

Use one canonical installed app:

```text
/Applications/Lock Anyway.app
```

Do not run a second copy from:

- `.build/release/Lock Anyway.app`
- `~/Applications/Lock Anyway.app`
- another downloaded copy

Duplicate app paths can make macOS Accessibility permission appear broken because permission may have been granted to a different signed app instance.
