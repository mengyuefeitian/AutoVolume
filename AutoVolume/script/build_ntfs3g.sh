#!/bin/bash
# Rebuilds the bundled ntfs-3g for the app's minimum macOS (14.0). Reproducible
# replacement for the manual build in docs/superpowers/plans/2026-09-20-ntfs-driver-findings.md.
#
# Set TARGET_ARCH=x86_64 to cross-compile the Intel release driver. FUSE-T ships
# universal (x86_64 + arm64) libs, so the same installed headers/libs serve both.
# arm64 keeps the historical flat Resources/NTFSDriver layout; every other arch
# lands in a per-arch subdirectory so both drivers can coexist in the repo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_ARCH="${TARGET_ARCH:-arm64}"
case "$TARGET_ARCH" in
  arm64|x86_64) ;;
  *) echo "error: TARGET_ARCH must be arm64 or x86_64 (got '$TARGET_ARCH')" >&2; exit 1 ;;
esac
WORK="${NTFS3G_WORK:-$ROOT/.ntfs3g-build-$TARGET_ARCH}"
FUSE_INCLUDE="${FUSE_INCLUDE:-/usr/local/include/fuse}"
FUSE_LIB="${FUSE_LIB:-/usr/local/lib}"
[[ -f "$FUSE_INCLUDE/fuse.h" ]] || { echo "error: fuse.h not found in $FUSE_INCLUDE (set FUSE_INCLUDE)" >&2; exit 1; }

# ntfs-3g needs the GNU build system, which macOS does not ship and Homebrew
# does not put on PATH by default. Discover it instead of assuming, so the
# script works from a plain shell.
for brew_prefix in /opt/homebrew /usr/local /home/linuxbrew/.linuxbrew; do
  if [[ -x "$brew_prefix/bin/autoreconf" ]]; then
    PATH="$brew_prefix/bin:$PATH"
    export PATH
    break
  fi
done
command -v autoreconf >/dev/null 2>&1 || {
  echo "error: autoreconf not found. Install the GNU build system:" >&2
  echo "  brew install autoconf automake libtool" >&2
  exit 1
}
# Homebrew installs libtool as glibtool/glibtoolize to avoid shadowing the
# system libtool, but autoreconf looks for plain `libtoolize`.
if ! command -v libtoolize >/dev/null 2>&1 && command -v glibtoolize >/dev/null 2>&1; then
  export LIBTOOLIZE="$(command -v glibtoolize)"
fi

# Reuse an existing checkout when one is present so repeated arch builds are
# cheap and don't churn large trees. Set NTFS3G_CLEAN=1 to force a fresh clone.
if [[ -d "$WORK/.git" && "${NTFS3G_CLEAN:-0}" != "1" ]]; then
  echo "Reusing existing checkout: $WORK"
else
  rm -rf "$WORK"
  git clone --depth 1 https://github.com/macos-fuse-t/ntfs-3g "$WORK"
fi
cd "$WORK"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CFLAGS="-arch $TARGET_ARCH -mmacosx-version-min=14.0 -O2"
export CPPFLAGS="-I$FUSE_INCLUDE"
export LDFLAGS="-arch $TARGET_ARCH -mmacosx-version-min=14.0 -L$FUSE_LIB -lfuse-t -Wl,-rpath,$FUSE_LIB"
./autogen.sh
./configure --prefix=/usr/local --exec-prefix=/usr/local --with-fuse=external \
  --sbindir=/usr/local/bin --bindir=/usr/local/bin --disable-static
make -j"$(sysctl -n hw.ncpu)"

if [[ "$TARGET_ARCH" == "arm64" ]]; then
  OUT="$ROOT/Resources/NTFSDriver"
else
  OUT="$ROOT/Resources/NTFSDriver/$TARGET_ARCH"
fi
mkdir -p "$OUT"
cp src/.libs/ntfs-3g "$OUT/ntfs-3g"
cp libntfs-3g/.libs/libntfs-3g.89.dylib "$OUT/libntfs-3g.89.dylib"
install_name_tool -id @loader_path/libntfs-3g.89.dylib "$OUT/libntfs-3g.89.dylib"
old_lib="$(otool -L "$OUT/ntfs-3g" | awk '/libntfs-3g\.89\.dylib/{print $1}')"
install_name_tool -change "$old_lib" @loader_path/libntfs-3g.89.dylib "$OUT/ntfs-3g"
for bin in "$OUT/ntfs-3g" "$OUT/libntfs-3g.89.dylib"; do
  old_fuse="$(otool -L "$bin" | awk '/libfuse-t/{print $1}')"
  [[ "$old_fuse" == "@rpath/libfuse-t.dylib" ]] || install_name_tool -change "$old_fuse" @rpath/libfuse-t.dylib "$bin"
done
otool -l "$OUT/ntfs-3g" | grep -q "path $FUSE_LIB" || install_name_tool -add_rpath "$FUSE_LIB" "$OUT/ntfs-3g"
chmod +x "$OUT/ntfs-3g"
echo "Built:"; for b in "$OUT/ntfs-3g" "$OUT/libntfs-3g.89.dylib"; do
  echo "$(basename "$b") $(lipo -archs "$b") minos=$(otool -l "$b" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"; done
