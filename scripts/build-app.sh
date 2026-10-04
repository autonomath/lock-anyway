#!/bin/zsh
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"

swift build -c release --product IdleLock >&2
bin_dir="$(swift build -c release --show-bin-path 2>/dev/null)"
executable="$bin_dir/IdleLock"

app_dir="$repo_dir/.build/release/Lock Anyway.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
icon_src="$repo_dir/Resources/AppIcon.icns"

if [[ ! -f "$icon_src" ]]; then
  swift "$repo_dir/scripts/generate-app-icon.swift" >&2
fi

rm -rf "$app_dir"
mkdir -p "$macos_dir" "$resources_dir"
cp "$executable" "$macos_dir/IdleLock"
cp "$repo_dir/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$icon_src" "$resources_dir/AppIcon.icns"
chmod 755 "$macos_dir/IdleLock"

if command -v codesign >/dev/null 2>&1; then
  sign_identity="${IDLE_LOCK_CODESIGN_IDENTITY:-}"
  if [[ -z "$sign_identity" ]] && command -v security >/dev/null 2>&1; then
    sign_identity="$(
      security find-identity -v -p codesigning 2>/dev/null \
        | awk -F '"' '/Developer ID Application/ { print $2; exit }'
    )"
  fi

  if [[ -n "$sign_identity" ]]; then
    if ! codesign --force --deep --options runtime --timestamp --sign "$sign_identity" "$app_dir" >&2; then
      codesign --force --deep --options runtime --sign "$sign_identity" "$app_dir" >&2
    fi
  else
    echo "No Developer ID Application identity found; using ad-hoc signing." >&2
    codesign --force --deep --sign - "$app_dir" >&2
  fi
fi

echo "$app_dir"
