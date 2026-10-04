#!/bin/zsh
set -euo pipefail

label="com.user.idle-lock-watchdog"
plist="$HOME/Library/LaunchAgents/$label.plist"
uid="$(id -u)"

launchctl bootout "gui/$uid" "$plist" >/dev/null 2>&1 || true
launchctl disable "gui/$uid/$label" >/dev/null 2>&1 || true

echo "Disabled $label"
echo "Left /Users/t/.local/bin/idle-lock-watchdog on disk for rollback"
