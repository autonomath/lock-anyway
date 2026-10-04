# Troubleshooting

## Accessibility Permission Keeps Appearing

Most likely cause: the wrong copy of the app is running.

Check the running path:

```sh
for pid in $(pgrep -x IdleLock); do ps -p "$pid" -o pid=,command=; done
```

Expected:

```text
/Applications/Lock Anyway.app/Contents/MacOS/IdleLock
```

If another path is running, quit it and reload:

```sh
scripts/reload-app.sh
```

Then grant Accessibility permission to the `/Applications` copy.

## The Warning Only Dims The Screen

The countdown panel should show a centered warning card with four add-time buttons and a Disable Locking button:

- 15 minutes
- 30 minutes
- 1 hour
- 2 hours

Clicking the dimmed background outside the card should dismiss the popup and cancel the countdown.

Moving the cursor to a screen edge during a countdown cancellation should hide the popup immediately instead of showing the temporary postponed message.

If only dimming appears, reload the current build:

```sh
scripts/reload-app.sh
```

Then test with a short custom delay such as `30s` and countdown `10 sec`.

## The Mac Does Not Lock

Open the log:

```sh
tail -n 80 ~/Library/Logs/LockAnyway.log
```

Expected lock strategy order:

1. Use `CGSession -suspend` if a working binary exists.
2. Otherwise use `Control-Command-Q` through Core Graphics events after Accessibility permission is trusted.

The app intentionally does not use `pmset displaysleepnow` as an automatic fallback.

## Start At Login Is Not Working

Check the LaunchAgent:

```sh
launchctl print gui/$(id -u)/com.user.idle-lock
```

Expected program:

```text
/Applications/Lock Anyway.app/Contents/MacOS/IdleLock
```

Reload the app if the LaunchAgent points somewhere else:

```sh
scripts/reload-app.sh
```

## Repeated Administrator Password Prompts

Normal development reloads should not ask for an administrator password. The reload script does not use AppleScript admin prompts.

If `/Applications/Lock Anyway.app` is root-owned or unwritable, build a package and install it manually:

```sh
scripts/package-app.sh
open dist/LockAnyway-1.1.0.pkg
```

Do not add an AppleScript `with administrator privileges` fallback to the reload script without an explicit reason.

## Logs

Main app log:

```text
~/Library/Logs/LockAnyway.log
```

LaunchAgent stdout/stderr:

```text
~/Library/Logs/LockAnyway.out.log
~/Library/Logs/LockAnyway.err.log
```
