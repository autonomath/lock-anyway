#!/bin/zsh
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
export COPYFILE_DISABLE=1

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
identifier="com.user.IdleLock"
app_src="$("$repo_dir/scripts/build-app.sh")"
dist_dir="$repo_dir/dist"
pkg_root="$repo_dir/.build/package-root"
component_pkg="$repo_dir/.build/IdleLock-component.pkg"
final_pkg="$dist_dir/LockAnyway-$version.pkg"

rm -rf "$pkg_root" "$component_pkg" "$final_pkg"
mkdir -p "$pkg_root/Applications" "$dist_dir"

ditto --norsrc --noextattr "$app_src" "$pkg_root/Applications/Lock Anyway.app"
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$pkg_root"
fi

pkgbuild \
  --root "$pkg_root" \
  --install-location "/" \
  --scripts "$repo_dir/Packaging/scripts" \
  --identifier "$identifier" \
  --version "$version" \
  "$component_pkg" >&2

installer_identity="${IDLE_LOCK_INSTALLER_IDENTITY:-}"
if [[ -z "$installer_identity" ]] && command -v security >/dev/null 2>&1; then
  installer_identity="$(
    security find-identity -v -p basic 2>/dev/null \
      | awk -F '"' '/Developer ID Installer/ { print $2; exit }'
  )"
fi

if [[ -n "$installer_identity" ]]; then
  productbuild \
    --package "$component_pkg" \
    --sign "$installer_identity" \
    "$final_pkg" >&2
else
  echo "No Developer ID Installer identity found; package will be unsigned." >&2
  productbuild \
    --package "$component_pkg" \
    "$final_pkg" >&2
fi

echo "$final_pkg"
