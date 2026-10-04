#!/bin/zsh
set -euo pipefail
setopt NULL_GLOB

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
export COPYFILE_DISABLE=1

app_name="Lock Anyway"
volume_name="Lock Anyway"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
dist_dir="$repo_dir/dist"
final_dmg="$dist_dir/LockAnyway.dmg"
temp_dmg="$dist_dir/LockAnyway-temp.dmg"
sign_dmg=1
notarize_dmg=0
notary_profile="${IDLE_LOCK_NOTARY_PROFILE:-}"
notary_keychain="${IDLE_LOCK_NOTARY_KEYCHAIN:-}"

usage() {
  cat <<EOF
Usage: scripts/package-dmg.sh [options]

Builds a signed drag-and-drop DMG for Lock Anyway.

Options:
  --version <v>          Create a versioned DMG filename instead of LockAnyway.dmg
  --no-sign-dmg          Skip code-signing the final DMG
  --notarize             Submit the final DMG for Apple notarization and staple it
  --notary-profile <p>   notarytool keychain profile name (default: IDLE_LOCK_NOTARY_PROFILE)
  --notary-keychain <k>  keychain path for notary profile lookup (default: IDLE_LOCK_NOTARY_KEYCHAIN)
  --help                 Show this help

Examples:
  scripts/package-dmg.sh
  scripts/package-dmg.sh --notarize --notary-profile TilePilot --notary-keychain "\$HOME/Library/Keychains/login.keychain-db"
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      shift
      version="${1:-}"
      if [[ -z "$version" ]]; then
        echo "--version requires a value" >&2
        exit 1
      fi
      final_dmg="$dist_dir/LockAnyway-$version.dmg"
      temp_dmg="$dist_dir/LockAnyway-$version-temp.dmg"
      ;;
    --no-sign-dmg)
      sign_dmg=0
      ;;
    --notarize)
      notarize_dmg=1
      ;;
    --notary-profile)
      shift
      notary_profile="${1:-}"
      if [[ -z "$notary_profile" ]]; then
        echo "--notary-profile requires a value" >&2
        exit 1
      fi
      ;;
    --notary-keychain)
      shift
      notary_keychain="${1:-}"
      if [[ -z "$notary_keychain" ]]; then
        echo "--notary-keychain requires a value" >&2
        exit 1
      fi
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

resolve_sign_identity() {
  if [[ -n "${IDLE_LOCK_CODESIGN_IDENTITY:-}" ]]; then
    echo "$IDLE_LOCK_CODESIGN_IDENTITY"
    return 0
  fi

  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F '"' '/Developer ID Application: / { print $2; exit }'
}

run_notarization() {
  local dmg_path="$1"

  if [[ -z "$notary_profile" ]]; then
    echo "Notarization requested, but no notary profile was provided." >&2
    echo "Set IDLE_LOCK_NOTARY_PROFILE or pass --notary-profile <profile>." >&2
    exit 1
  fi

  local -a notary_args=(
    submit "$dmg_path"
    --keychain-profile "$notary_profile"
    --wait
  )

  if [[ -n "$notary_keychain" ]]; then
    notary_args+=(--keychain "$notary_keychain")
  fi

  echo "Submitting DMG for notarization with profile: $notary_profile" >&2
  xcrun notarytool "${notary_args[@]}"

  echo "Stapling notarization ticket..." >&2
  xcrun stapler staple "$dmg_path"
  xcrun stapler validate "$dmg_path"

  echo "Gatekeeper assessment after notarization:" >&2
  spctl -a -vv --type open --context context:primary-signature "$dmg_path"
}

echo "Building signed release app..." >&2
app_src="$("$repo_dir/scripts/build-app.sh")"

if [[ ! -d "$app_src" ]]; then
  echo "Expected app not found at: $app_src" >&2
  exit 1
fi

codesign --verify --deep --strict "$app_src"

mkdir -p "$dist_dir"
rm -f "$final_dmg" "$temp_dmg"

if [[ -d "/Volumes/$volume_name" ]]; then
  hdiutil detach "/Volumes/$volume_name" -force >/dev/null 2>&1 || true
fi

stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/lock-anyway-dmg-stage.XXXXXX")"
trap 'hdiutil detach "/Volumes/'"$volume_name"'" -force >/dev/null 2>&1 || true; rm -rf "$stage_dir"' EXIT

ditto --norsrc --noextattr "$app_src" "$stage_dir/$app_name.app"
ln -s /Applications "$stage_dir/Applications"

echo "Creating read/write DMG..." >&2
hdiutil create \
  -volname "$volume_name" \
  -srcfolder "$stage_dir" \
  -fs APFS \
  -format UDRW \
  -ov \
  "$temp_dmg" >/dev/null

echo "Applying Finder layout..." >&2
attach_output="$(hdiutil attach -readwrite -noverify -noautoopen "$temp_dmg")"
device="$(echo "$attach_output" | awk '/\/Volumes\// { print $1; exit }')"
mount_point="$(echo "$attach_output" | awk '/\/Volumes\// { print $NF; exit }')"

if [[ -z "$device" || -z "$mount_point" ]]; then
  echo "Failed to mount temporary DMG." >&2
  exit 1
fi

finder_disk_ready=0
for _ in {1..20}; do
  if /usr/bin/osascript -e 'tell application "Finder" to exists disk "'"$volume_name"'"' 2>/dev/null | grep -q "true"; then
    finder_disk_ready=1
    break
  fi
  sleep 0.5
done

if [[ "$finder_disk_ready" -ne 1 ]]; then
  echo "Finder did not register mounted DMG volume: $volume_name at $mount_point" >&2
  exit 1
fi

/usr/bin/osascript <<EOF
tell application "Finder"
  tell disk "$volume_name"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {120, 120, 860, 560}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set position of item "$app_name.app" of container window to {220, 250}
    set position of item "Applications" of container window to {540, 250}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
EOF

sync
hdiutil detach "$device" >/dev/null

echo "Creating compressed DMG..." >&2
hdiutil convert "$temp_dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$final_dmg" >/dev/null
rm -f "$temp_dmg"

if [[ $sign_dmg -eq 1 ]]; then
  sign_identity="$(resolve_sign_identity)"
  if [[ -n "$sign_identity" ]]; then
    echo "Signing DMG with: $sign_identity" >&2
    codesign --force --timestamp --sign "$sign_identity" "$final_dmg"
    codesign --verify --verbose "$final_dmg"
  else
    echo "No Developer ID Application identity found; leaving DMG unsigned." >&2
  fi
fi

if [[ $notarize_dmg -eq 1 ]]; then
  run_notarization "$final_dmg"
elif command -v hdiutil >/dev/null 2>&1; then
  hdiutil verify "$final_dmg" >/dev/null
fi

echo "$final_dmg"
