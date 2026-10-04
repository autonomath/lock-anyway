#!/bin/zsh
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
export COPYFILE_DISABLE=1

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
dist_dir="$repo_dir/dist"
pkg_path="${1:-$dist_dir/LockAnyway-$version.pkg}"
dmg_path="${2:-$dist_dir/LockAnyway.dmg}"

if [[ ! -f "$pkg_path" ]]; then
  echo "Missing package: $pkg_path" >&2
  echo "Build it first with: scripts/package-app.sh" >&2
  exit 1
fi

if [[ ! -f "$dmg_path" ]]; then
  echo "Missing DMG: $dmg_path" >&2
  echo "Build it first with: scripts/package-dmg.sh" >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun is required for notarytool and stapler." >&2
  exit 1
fi

auth_args=()
if [[ -n "${IDLE_LOCK_NOTARY_PROFILE:-}" ]]; then
  auth_args=(--keychain-profile "$IDLE_LOCK_NOTARY_PROFILE")
elif [[ -n "${IDLE_LOCK_NOTARY_KEY:-}" && -n "${IDLE_LOCK_NOTARY_KEY_ID:-}" ]]; then
  auth_args=(--key "$IDLE_LOCK_NOTARY_KEY" --key-id "$IDLE_LOCK_NOTARY_KEY_ID")
  if [[ -n "${IDLE_LOCK_NOTARY_ISSUER:-}" ]]; then
    auth_args+=(--issuer "$IDLE_LOCK_NOTARY_ISSUER")
  fi
elif [[ -n "${IDLE_LOCK_NOTARY_APPLE_ID:-}" && -n "${IDLE_LOCK_NOTARY_PASSWORD:-}" && -n "${IDLE_LOCK_NOTARY_TEAM_ID:-}" ]]; then
  auth_args=(--apple-id "$IDLE_LOCK_NOTARY_APPLE_ID" --password "$IDLE_LOCK_NOTARY_PASSWORD" --team-id "$IDLE_LOCK_NOTARY_TEAM_ID")
else
  cat >&2 <<'EOF'
No Apple notarization credentials were found.

Recommended one-time setup:
  xcrun notarytool store-credentials lock-anyway --apple-id "you@example.com" --team-id "RJL9XWBZ9L"

Then run:
  IDLE_LOCK_NOTARY_PROFILE=lock-anyway scripts/notarize-release.sh

Alternatively set App Store Connect API key variables:
  IDLE_LOCK_NOTARY_KEY=/path/AuthKey_XXXXXXXXXX.p8
  IDLE_LOCK_NOTARY_KEY_ID=XXXXXXXXXX
  IDLE_LOCK_NOTARY_ISSUER=00000000-0000-0000-0000-000000000000

Or Apple ID variables:
  IDLE_LOCK_NOTARY_APPLE_ID=you@example.com
  IDLE_LOCK_NOTARY_PASSWORD=app-specific-password
  IDLE_LOCK_NOTARY_TEAM_ID=RJL9XWBZ9L
EOF
  exit 2
fi

notarize_and_staple() {
  local artifact="$1"
  echo "Submitting $(basename "$artifact") for notarization..." >&2
  xcrun notarytool submit "$artifact" "${auth_args[@]}" --wait --timeout 45m

  echo "Stapling notarization ticket to $(basename "$artifact")..." >&2
  xcrun stapler staple "$artifact"
  xcrun stapler validate "$artifact"
}

notarize_and_staple "$pkg_path"
notarize_and_staple "$dmg_path"

pkgutil --check-signature "$pkg_path"
spctl -a -vv --type install "$pkg_path"

if hdiutil verify "$dmg_path" >/dev/null; then
  echo "DMG checksum is valid." >&2
fi

(
  cd "$dist_dir"
  shasum -a 256 "$(basename "$pkg_path")" "$(basename "$dmg_path")" > SHA256SUMS.txt
)

echo "Notarized release artifacts:"
echo "$pkg_path"
echo "$dmg_path"
echo "$dist_dir/SHA256SUMS.txt"
