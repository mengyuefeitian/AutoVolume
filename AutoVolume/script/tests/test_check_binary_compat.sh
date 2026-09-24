#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/script/check_binary_compat.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

make_app() { # $1=app dir, $2=Info.plist min, $3=binary minos
  mkdir -p "$1/Contents/MacOS" "$1/Contents/Frameworks"
  /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $2" "$1/Contents/Info.plist" >/dev/null
  printf 'int main(void){return 0;}\n' > "$TMP/m.c"
  clang -arch arm64 -mmacosx-version-min="$3" -o "$1/Contents/MacOS/Main" "$TMP/m.c"
  printf 'int f(void){return 1;}\n' > "$TMP/f.c"
  clang -arch arm64 -mmacosx-version-min=14.0 -dynamiclib -o "$1/Contents/Frameworks/libF.dylib" "$TMP/f.c"
}

make_app "$TMP/Good.app" 14.0 14.0
"$GATE" "$TMP/Good.app" >/dev/null || { echo "FAIL: good bundle rejected"; exit 1; }
[[ "$("$GATE" "$TMP/Good.app" --print-max-minos)" == "14.0" ]] || { echo "FAIL: max minos not 14.0"; exit 1; }

make_app "$TMP/Bad.app" 14.0 26.0
if "$GATE" "$TMP/Bad.app" > "$TMP/out.txt" 2>&1; then echo "FAIL: minos 26 bundle accepted"; exit 1; fi
grep -q "Contents/MacOS/Main minos=26.0" "$TMP/out.txt" || { echo "FAIL: offender not reported"; cat "$TMP/out.txt"; exit 1; }

mkdir -p "$TMP/X86.app/Contents/MacOS"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" "$TMP/X86.app/Contents/Info.plist" >/dev/null
clang -arch x86_64 -mmacosx-version-min=14.0 -o "$TMP/X86.app/Contents/MacOS/Main" "$TMP/m.c"
if "$GATE" "$TMP/X86.app" >/dev/null 2>&1; then echo "FAIL: x86_64-only bundle accepted"; exit 1; fi

echo "PASS: check_binary_compat"
