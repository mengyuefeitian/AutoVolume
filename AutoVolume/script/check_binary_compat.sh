#!/bin/bash
# Fails if any Mach-O in the bundle needs a newer macOS than Info.plist promises,
# or lacks a slice for the architecture being shipped. Guards against the
# 0.1.38–0.1.48 regression where binaries shipped with minos 26/28 while
# LSMinimumSystemVersion said 14.0.
#
# Target architecture comes from TARGET_ARCH (default: arm64) so the same gate
# serves both the arm64 and x86_64 release builds. Defaulting to arm64 keeps
# the historical behaviour — an x86_64-only bundle is still rejected unless the
# caller explicitly asked for an x86_64 build.
set -euo pipefail
APP="${1:?Usage: check_binary_compat.sh <App.app> [--print-max-minos]}"
MODE="${2:-}"
TARGET_ARCH="${TARGET_ARCH:-arm64}"
case "$TARGET_ARCH" in
  arm64|x86_64) ;;
  *) echo "error: TARGET_ARCH must be arm64 or x86_64 (got '$TARGET_ARCH')" >&2; exit 1 ;;
esac
PLIST_MIN="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"

version_gt() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" == "$1" && "$1" != "$2" ]]; }

max="0.0"; failed=0
while IFS= read -r -d '' file; do
  file -b "$file" | grep -q 'Mach-O' || continue
  archs="$(lipo -archs "$file" 2>/dev/null || true)"
  if [[ " $archs " != *" $TARGET_ARCH "* ]]; then
    echo "${file#$APP/} missing $TARGET_ARCH (archs=$archs)" >&2; failed=1
  fi
  for arch in $archs; do
    minos="$(otool -arch "$arch" -l "$file" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
    [[ -z "$minos" ]] && minos="$(otool -arch "$arch" -l "$file" | awk '/LC_VERSION_MIN_MACOSX/{f=1} f&&/version/{print $2; exit}')"
    [[ -z "$minos" ]] && continue
    version_gt "$minos" "$max" && max="$minos"
    if version_gt "$minos" "$PLIST_MIN"; then
      echo "${file#$APP/} minos=$minos arch=$arch (> LSMinimumSystemVersion $PLIST_MIN)" >&2; failed=1
    fi
  done
done < <(find "$APP" -type f -print0)

[[ "$MODE" == "--print-max-minos" ]] && echo "$max"
exit "$failed"
