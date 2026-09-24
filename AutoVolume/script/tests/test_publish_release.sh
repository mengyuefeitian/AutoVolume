#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
APPB="$TMP/AutoVolume.app"; mkdir -p "$APPB/Contents/MacOS"
for kv in "CFBundleShortVersionString string 0.1.50" "CFBundleVersion string 50" "LSMinimumSystemVersion string 14.0"; do
  /usr/libexec/PlistBuddy -c "Add :$kv" "$APPB/Contents/Info.plist" >/dev/null; done
printf 'int main(void){return 0;}\n' > "$TMP/m.c"
clang -arch arm64 -mmacosx-version-min=14.0 -o "$APPB/Contents/MacOS/AutoVolume" "$TMP/m.c"
printf '#!/bin/bash\necho '"'"'sparkle:edSignature="SIG==" length="123"'"'"'\n' > "$TMP/sign_update"; chmod +x "$TMP/sign_update"
touch "$TMP/key" "$TMP/AutoVolume-0.1.50-local.dmg"
cat > "$TMP/appcast.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>AutoVolume Updates</title>
  </channel>
</rss>
XML
APP_BUNDLE="$APPB" APPCAST_PATH="$TMP/appcast.xml" SIGN_UPDATE="$TMP/sign_update" SPARKLE_PRIVATE_KEY_FILE="$TMP/key" \
  bash "$ROOT/script/publish_release.sh" "$TMP/AutoVolume-0.1.50-local.dmg" >/dev/null
X="$TMP/appcast.xml"
xmllint --noout "$X" || { echo "FAIL: appcast not well-formed"; exit 1; }
grep -q "<sparkle:version>50</sparkle:version>" "$X" || { echo "FAIL: sparkle:version must be integer CFBundleVersion"; exit 1; }
grep -q "<sparkle:shortVersionString>0.1.50</sparkle:shortVersionString>" "$X" || { echo "FAIL: short version"; exit 1; }
grep -q "<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>" "$X" || { echo "FAIL: min system version"; exit 1; }
grep -q 'releases/download/v0.1.50/AutoVolume-0.1.50-local.dmg' "$X" || { echo "FAIL: download url"; exit 1; }
[[ "$(grep -c 'length=' "$X")" == "1" ]] || { echo "FAIL: duplicate length attribute"; exit 1; }
echo "PASS: publish_release"

# Important 4 (final review): publish_release.sh must read versions from the app
# bundle actually embedded in the DMG being published (not from a possibly-stale
# dist/AutoVolume.app) whenever APP_BUNDLE is not explicitly overridden. Build a
# real, throwaway DMG containing its own Info.plist/version and verify the
# attach -> read -> detach path.
TMP2="$(mktemp -d)"; trap 'rm -rf "$TMP" "$TMP2"' EXIT
hdiutil create -size 20m -fs HFS+ -volname AutoVolumePublishTest -ov "$TMP2/rw.dmg" >/dev/null
ATTACH_OUT="$(hdiutil attach -nobrowse -noautoopen "$TMP2/rw.dmg")"
MP="$(printf '%s\n' "$ATTACH_OUT" | grep -Eo '/Volumes/.*$' | tail -n 1)"
[[ -n "$MP" ]] || { echo "FAIL: could not attach throwaway rw dmg"; exit 1; }
mkdir -p "$MP/AutoVolume.app/Contents/MacOS"
for kv in "CFBundleShortVersionString string 0.1.77" "CFBundleVersion string 77" "LSMinimumSystemVersion string 14.0"; do
  /usr/libexec/PlistBuddy -c "Add :$kv" "$MP/AutoVolume.app/Contents/Info.plist" >/dev/null; done
printf 'int main(void){return 0;}\n' > "$TMP2/m.c"
clang -arch arm64 -mmacosx-version-min=14.0 -o "$MP/AutoVolume.app/Contents/MacOS/AutoVolume" "$TMP2/m.c"
hdiutil detach "$MP" -quiet

printf '#!/bin/bash\necho '"'"'sparkle:edSignature="SIG==" length="123"'"'"'\n' > "$TMP2/sign_update"; chmod +x "$TMP2/sign_update"
touch "$TMP2/key"
cat > "$TMP2/appcast.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>AutoVolume Updates</title>
  </channel>
</rss>
XML

# No APP_BUNDLE override here — the script must attach $TMP2/rw.dmg itself and
# derive the version from the app bundle it finds inside.
APPCAST_PATH="$TMP2/appcast.xml" SIGN_UPDATE="$TMP2/sign_update" SPARKLE_PRIVATE_KEY_FILE="$TMP2/key" \
  bash "$ROOT/script/publish_release.sh" "$TMP2/rw.dmg" >/dev/null
X2="$TMP2/appcast.xml"
xmllint --noout "$X2" || { echo "FAIL: DMG-derived appcast not well-formed"; exit 1; }
grep -q "<sparkle:version>77</sparkle:version>" "$X2" || { echo "FAIL: DMG-derived sparkle:version must come from the DMG's embedded app, not APP_BUNDLE"; exit 1; }
grep -q "<sparkle:shortVersionString>0.1.77</sparkle:shortVersionString>" "$X2" || { echo "FAIL: DMG-derived short version"; exit 1; }
mount | grep -q "AutoVolumePublishTest" && { echo "FAIL: publish_release.sh left the DMG attached"; exit 1; }
echo "PASS: publish_release (DMG-derived version, attach/detach)"
