#!/bin/zsh
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
uid="$(id -u)"
label="com.user.idle-lock"
app_src="$("$repo_dir/scripts/build-app.sh")"
app_dst="/Applications/Lock Anyway.app"
plist="$HOME/Library/LaunchAgents/$label.plist"

if [[ ! -w /Applications ]]; then
  echo "Cannot write to /Applications without administrator authorization." >&2
  echo "Run scripts/package-app.sh and open the generated dist/LockAnyway-<version>.pkg to install manually." >&2
  exit 1
fi

launchctl bootout "gui/$uid" "$plist" >/dev/null 2>&1 || true
pkill -x IdleLock >/dev/null 2>&1 || true

if [[ -e "$app_dst" ]]; then
  if [[ -w "$app_dst" && -w "$app_dst/Contents" ]]; then
    rm -rf "$app_dst"
  else
    backup="/Applications/.IdleLock.previous-root-owned.$(/bin/date +%Y%m%d%H%M%S)"
    mv "$app_dst" "$backup"
    echo "Moved previous root-owned app bundle to $backup" >&2
  fi
fi

ditto --norsrc --noextattr "$app_src" "$app_dst"

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/Lock Anyway.app/Contents/MacOS/IdleLock</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/LockAnyway.out.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/LockAnyway.err.log</string>
</dict>
</plist>
PLIST

plutil -lint "$plist" >/dev/null
launchctl bootstrap "gui/$uid" "$plist"
launchctl enable "gui/$uid/$label"
launchctl kickstart -k "gui/$uid/$label" >/dev/null 2>&1 || true

legacy_app="/Applications/Idle Lock.app"
if [[ -d "$legacy_app" ]]; then
  legacy_backup="/Applications/.Idle Lock.previous.$(/bin/date +%Y%m%d%H%M%S)"
  mv "$legacy_app" "$legacy_backup"
  echo "Moved the previous Idle Lock app to $legacy_backup"
fi

echo "Reloaded Lock Anyway from /Applications/Lock Anyway.app"
