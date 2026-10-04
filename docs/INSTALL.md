# Install Guide

## Normal User Install

Build the DMG:

```sh
scripts/package-dmg.sh
```

Open:

```text
dist/LockAnyway.dmg
```

Drag `Lock Anyway.app` to Applications, then open it from:

```text
/Applications/Lock Anyway.app
```

Do not run the app directly from the mounted disk image. The app will refuse to run from `/Volumes/...` because that would attach Start at Login and Accessibility permission to the wrong app path.

## Managed Package Install

Build the installer package:

```sh
scripts/package-app.sh
```

Open this package in Finder:

```text
dist/LockAnyway-1.1.0.pkg
```

The current package installs:

- `/Applications/Lock Anyway.app`
- `~/Library/LaunchAgents/com.user.idle-lock.plist`
- `~/Library/Logs/LockAnyway.log`

The package installs and starts the app automatically.

## First Launch

On modern macOS, `CGSession` may be unavailable. In that case the app falls back to sending the native `Control-Command-Q` lock shortcut, which requires Accessibility permission.

Grant permission when macOS asks. If the app is disabled because permission is missing, click the status row in the menu to open the permission prompt.

If permission was granted to a different copy of the app, remove the duplicate copy and run only:

```text
/Applications/Lock Anyway.app
```

## Start At Login

The app writes a user LaunchAgent:

```text
~/Library/LaunchAgents/com.user.idle-lock.plist
```

The LaunchAgent uses:

- `RunAtLoad = true`
- `KeepAlive = { SuccessfulExit = false }`

That means a crash restarts the app, but choosing Quit does not immediately relaunch it.

## Source Checkout Install

For development machines where `/Applications` is writable:

```sh
scripts/install-app.sh
```

This installs the same canonical app path:

```text
/Applications/Lock Anyway.app
```

If `/Applications` is not writable without administrator authorization, use the package installer instead.

## Updating

For a normal user, replace the app from the new DMG.

For a managed install, install the new package over the old one.

For development:

```sh
scripts/reload-app.sh
```

The reload script rebuilds, signs, installs to `/Applications/Lock Anyway.app`, rewrites the LaunchAgent, and restarts the app. It should not ask for an administrator password during normal development.

## Old Watchdog Migration

Keep the existing watchdog until this app has been manually verified. After verification:

```sh
scripts/disable-old-watchdog.sh
```

The old binary remains on disk for rollback:

```text
~/.local/bin/idle-lock-watchdog
```
