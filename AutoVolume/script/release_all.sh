#!/bin/bash
# Builds and packages AutoVolume for both shipping architectures.
#
# Every release ships two installers:
#   AutoVolume-<v>.dmg          (arm64 — the historical name, unchanged)
#   AutoVolume-<v>-x86_64.dmg   (Intel)
# Both are cut from the same source tree at the same version — only TARGET_ARCH
# differs. Order matters: each architecture is built and then packaged
# immediately, because both builds write to the same dist/AutoVolume.app.
# Packaging before moving on is what keeps the two artifacts from ever being
# confused.
#
# Usage: script/release_all.sh <version>
#   version must match Resources/Info.plist CFBundleShortVersionString.
#
# To publish afterwards, sign and insert each artifact separately — they land in
# different appcasts:
#   script/publish_release.sh dist/AutoVolume-<v>.dmg
#   script/publish_release.sh dist/AutoVolume-<v>-x86_64.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?Usage: release_all.sh <version> (must match Info.plist CFBundleShortVersionString)}"

# Pin the SDK: the default MacOSX27.0.sdk breaks multi-file Foundation targets
# under this toolchain (see CLAUDE.md "Build environment note").
export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
export MACOSX_DEPLOYMENT_TARGET=14.0

if [[ ! -d "$SDKROOT" ]]; then
  echo "error: SDK not found at $SDKROOT — set SDKROOT to a working SDK" >&2
  exit 1
fi

PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
if [[ "$VERSION" != "$PLIST_VERSION" ]]; then
  echo "error: version '$VERSION' does not match Resources/Info.plist ('$PLIST_VERSION')" >&2
  exit 1
fi

PRODUCED=()
for ARCH in arm64 x86_64; do
  echo ""
  echo "=== Building $ARCH ==="
  TARGET_ARCH="$ARCH" "$ROOT/script/build_and_run.sh" --no-launch

  # Belt-and-braces: confirm the bundle on disk really is this architecture
  # before it gets sealed into a DMG. build_and_run.sh already runs
  # check_binary_compat.sh, but this is the last point where a mix-up is cheap.
  MAIN_BINARY="$ROOT/dist/AutoVolume.app/Contents/MacOS/AutoVolume"
  ACTUAL="$(lipo -archs "$MAIN_BINARY" 2>/dev/null || true)"
  if [[ " $ACTUAL " != *" $ARCH "* ]]; then
    echo "error: built binary is '$ACTUAL', expected $ARCH — aborting before packaging" >&2
    exit 1
  fi

  echo "=== Packaging $ARCH ==="
  TARGET_ARCH="$ARCH" "$ROOT/script/package_dmg.sh" "$VERSION"
  if [[ "$ARCH" == "x86_64" ]]; then
    PRODUCED+=("$ROOT/dist/AutoVolume-$VERSION-x86_64.dmg")
  else
    PRODUCED+=("$ROOT/dist/AutoVolume-$VERSION.dmg")
  fi
done

echo ""
echo "Built ${#PRODUCED[@]} installers for version $VERSION:"
for dmg in "${PRODUCED[@]}"; do
  echo "  $dmg"
done
echo ""
echo "Next: publish each into its own appcast (they must not be swapped):"
for dmg in "${PRODUCED[@]}"; do
  echo "  script/publish_release.sh ${dmg#$ROOT/}"
done
