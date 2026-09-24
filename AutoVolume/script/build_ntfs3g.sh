#!/bin/bash
# Rebuilds the bundled ntfs-3g for the app's minimum macOS (14.0). Reproducible
# replacement for the manual build in docs/superpowers/plans/2026-09-20-ntfs-driver-findings.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${NTFS3G_WORK:-$ROOT/.ntfs3g-build}"
FUSE_INCLUDE="${FUSE_INCLUDE:-/usr/local/include/fuse}"
FUSE_LIB="${FUSE_LIB:-/usr/local/lib}"
[[ -f "$FUSE_INCLUDE/fuse.h" ]] || { echo "error: fuse.h not found in $FUSE_INCLUDE (set FUSE_INCLUDE)" >&2; exit 1; }

rm -rf "$WORK"; git clone --depth 1 https://github.com/macos-fuse-t/ntfs-3g "$WORK"
cd "$WORK"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CFLAGS="-arch arm64 -mmacosx-version-min=14.0 -O2"
export CPPFLAGS="-I$FUSE_INCLUDE"
export LDFLAGS="-arch arm64 -mmacosx-version-min=14.0 -L$FUSE_LIB -lfuse-t -Wl,-rpath,$FUSE_LIB"
./autogen.sh
./configure --prefix=/usr/local --exec-prefix=/usr/local --with-fuse=external \
  --sbindir=/usr/local/bin --bindir=/usr/local/bin --disable-static
make -j"$(sysctl -n hw.ncpu)"

OUT="$ROOT/Resources/NTFSDriver"
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
