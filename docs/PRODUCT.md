# Product And Naming

## Product Name

Recommended public name: **Lock Anyway**

Tagline: **Apps can keep your Mac awake. Not unlocked.**

One-line description:

> Lock Anyway locks your Mac after real keyboard and mouse inactivity, even when media, remote desktop, or a single misbehaving process keeps the display awake.

## Why This Name

The research found nearby categories, but no exact consumer-friendly match:

- Keep-awake tools such as Amphetamine, Caffeine, Lungo, and KeepingYouAwake solve the opposite problem.
- Break reminder apps have the warning/snooze overlay pattern, but they do not lock the Mac after true idle time.
- Proximity lock apps use Bluetooth, iPhone, Apple Watch, or camera signals rather than real HID idle time.
- Admin scripts can enforce idle lock, but they are not approachable for normal Mac users.

The first naming pass over-emphasized the countdown grace period. The real missing piece is stricter:

> Another process can keep the Mac awake, but it should not keep the user session unlocked.

**Lock Anyway** captures that promise directly. YouTube, RustDesk, a download helper, or a buggy process can block display sleep; the Mac locks anyway.

## Bundle Identity

The public app ships as:

- Display app: `Lock Anyway.app`
- Bundle id: `com.user.IdleLock`
- Executable: `IdleLock`
- LaunchAgent: `com.user.idle-lock`
- Log file: `~/Library/Logs/LockAnyway.log`

Keep the installed app at `/Applications/Lock Anyway.app`. macOS Accessibility permission is sensitive to bundle identity, signing, and app path.

## Product Promise

Lock Anyway should be understandable to a normal Mac user:

- Set how long the Mac may be idle.
- See a clear countdown before lock.
- Press a button or number key to add time.
- Disable locking from the popup when the Mac should stay unlocked until resumed.
- Move the mouse, press a key, or click the dimmed background to cancel.
- Let media, downloads, and remote desktop keep running while the local session locks.
- Stop one awake-keeping process from leaving the Mac unlocked all day.

## Non-Goals

- It is not a keep-awake app.
- It is not a break reminder app.
- It is not a Bluetooth proximity lock.
- It is not an MDM/compliance dashboard.
- It does not auto-pause for fullscreen video by default.

## UI Copy

Countdown copy:

> Locking in 30 seconds. Move mouse or press any key to stay unlocked.

Add-time buttons:

- `1  15 minutes`
- `2  30 minutes`
- `3  1 hour`
- `4  2 hours`

Popup action:

- `Disable Locking`

Accessibility copy:

> Lock Anyway needs Accessibility permission only to send the macOS Lock Screen shortcut if the legacy lock command is unavailable.
