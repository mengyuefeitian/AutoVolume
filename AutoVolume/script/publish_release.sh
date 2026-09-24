#!/usr/bin/env bash
set -euo pipefail

# Signs a release .dmg with Sparkle's EdDSA key and inserts the resulting
# <item> at the top of docs/appcast.xml (repo root, served by GitHub Pages
# as main:/docs). Manual, per-release — not run by CI. Requires the private
# key file exported via `generate_keys -x` to be present at
# SPARKLE_PRIVATE_KEY_FILE. Deliberately not Keychain-based: the private key
# lives only in a plain, owner-only file outside git, never in macOS
# Keychain.
#
# Version numbers are read from the app bundle actually embedded inside the
# DMG being published, not passed on the command line and not read from
# dist/AutoVolume.app: AutoVolume's CFBundleVersion is a plain integer (e.g.
# 50) while CFBundleShortVersionString is dotted (0.1.50). Sparkle compares
# sparkle:version against CFBundleVersion, so the appcast entry must carry
# the integer, not the dotted string. Reading from the DMG itself (rather
# than a possibly-stale local dist/AutoVolume.app build) guarantees the
# appcast always describes what's actually inside the artifact being signed
# and uploaded.

DMG_PATH="${1:?Usage: publish_release.sh <path-to-dmg>}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/.." && pwd)"

APPCAST_PATH="${APPCAST_PATH:-$REPO_ROOT/docs/appcast.xml}"
SPARKLE_PRIVATE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-$HOME/.config/autovolume/sparkle_signing_key}"

if [ ! -f "$SPARKLE_PRIVATE_KEY_FILE" ]; then
  echo "error: private key file not found at $SPARKLE_PRIVATE_KEY_FILE — set SPARKLE_PRIVATE_KEY_FILE or run 'generate_keys -x <file>' first" >&2
  exit 1
fi

if [ ! -f "$APPCAST_PATH" ]; then
  echo "error: appcast not found at $APPCAST_PATH" >&2
  exit 1
fi

if [ ! -f "$DMG_PATH" ]; then
  echo "error: dmg not found at $DMG_PATH" >&2
  exit 1
fi

# Resolve the app bundle to inspect. An explicit APP_BUNDLE override is
# trusted as-is (this is the test path: test_publish_release.sh passes a
# fake, unattachable DMG alongside a real APP_BUNDLE it built by hand).
# Otherwise, attach the DMG read-only and use the .app bundle mounted from
# it, then detach on exit regardless of how the script terminates.
MOUNT_POINT=""
cleanup() {
  if [ -n "$MOUNT_POINT" ]; then
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [ -n "${APP_BUNDLE:-}" ]; then
  RESOLVED_APP_BUNDLE="$APP_BUNDLE"
else
  ATTACH_OUTPUT="$(hdiutil attach -readonly -nobrowse -noautoopen "$DMG_PATH")"
  MOUNT_POINT="$(printf '%s\n' "$ATTACH_OUTPUT" | grep -Eo '/Volumes/.*$' | tail -n 1)"
  if [ -z "$MOUNT_POINT" ]; then
    echo "error: could not determine the mount point after attaching $DMG_PATH" >&2
    exit 1
  fi
  RESOLVED_APP_BUNDLE="$(find "$MOUNT_POINT" -maxdepth 1 -name '*.app' -print -quit)"
  if [ -z "$RESOLVED_APP_BUNDLE" ]; then
    echo "error: no .app bundle found inside $DMG_PATH (mounted at $MOUNT_POINT)" >&2
    exit 1
  fi
fi

if [ ! -d "$RESOLVED_APP_BUNDLE" ]; then
  echo "error: $RESOLVED_APP_BUNDLE not found — build the app first with 'bash script/build_and_run.sh' before running publish_release.sh" >&2
  exit 1
fi

APP_INFO_PLIST="$RESOLVED_APP_BUNDLE/Contents/Info.plist"

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_INFO_PLIST" 2>/dev/null || true)"
if [ -z "$SHORT_VERSION" ]; then
  echo "error: CFBundleShortVersionString not found in $APP_INFO_PLIST" >&2
  exit 1
fi

BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_INFO_PLIST" 2>/dev/null || true)"
if [ -z "$BUNDLE_VERSION" ]; then
  echo "error: CFBundleVersion not found in $APP_INFO_PLIST" >&2
  exit 1
fi

# Prefer the known-correct EdDSA sign_update path (Sparkle ships it
# pre-built inside the resolved package artifacts — it is not an SPM
# product, so it can't be built with `swift build --product sign_update`).
# Fall back to a find-based search (excluding the legacy DSA bash script at
# old_dsa_scripts/sign_update, which takes different arguments) in case the
# exact path shifts in a future Sparkle version.
SIGN_UPDATE="${SIGN_UPDATE:-$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update}"
if [ ! -f "$SIGN_UPDATE" ]; then
  SIGN_UPDATE="$(find "$ROOT_DIR/.build" -name "sign_update" -type f -not -path "*old_dsa_scripts*" 2>/dev/null | head -n 1)"
fi

if [ -z "$SIGN_UPDATE" ] || [ ! -f "$SIGN_UPDATE" ]; then
  echo "error: sign_update tool not found under .build — run 'swift package resolve' first" >&2
  exit 1
fi

# Derive minimumSystemVersion from the actual built binaries via the
# compat gate (Task 1) rather than trusting Info.plist's
# LSMinimumSystemVersion at face value — the gate fails if any binary in
# the bundle actually needs a newer macOS than the plist promises,
# preventing a stale/wrong value from ever reaching the appcast.
MIN_SYSTEM_VERSION="$("$ROOT_DIR/script/check_binary_compat.sh" "$RESOLVED_APP_BUNDLE" --print-max-minos)" \
  || { echo "error: check_binary_compat.sh failed — fix binary/Info.plist minos mismatch before publishing" >&2; exit 1; }
if [ -z "$MIN_SYSTEM_VERSION" ]; then
  echo "error: check_binary_compat.sh did not print a minimum system version" >&2
  exit 1
fi

# sign_update's stdout already includes both sparkle:edSignature and length
# attributes — do not add a second length= here, it would produce invalid
# XML (duplicate attribute on the same element).
SIGNATURE_LINE="$("$SIGN_UPDATE" -f "$SPARKLE_PRIVATE_KEY_FILE" "$DMG_PATH")"
DOWNLOAD_URL="https://github.com/mengyuefeitian/AutoVolume/releases/download/v${SHORT_VERSION}/$(basename "$DMG_PATH")"

if grep -q "<sparkle:version>${BUNDLE_VERSION}</sparkle:version>" "$APPCAST_PATH"; then
  echo "error: appcast already has an item with sparkle:version ${BUNDLE_VERSION}" >&2
  exit 1
fi

ITEM_XML="    <item>
      <title>Version ${SHORT_VERSION}</title>
      <pubDate>$(date -R)</pubDate>
      <sparkle:version>${BUNDLE_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_SYSTEM_VERSION}</sparkle:minimumSystemVersion>
      <enclosure
        url=\"${DOWNLOAD_URL}\"
        type=\"application/octet-stream\"
        ${SIGNATURE_LINE} />
    </item>"

ITEM_XML="$ITEM_XML" python3 - "$APPCAST_PATH" <<'PYEOF'
import os
import sys

path = sys.argv[1]
item_xml = os.environ["ITEM_XML"]

with open(path, "r", encoding="utf-8") as f:
    content = f.read()

marker = "<title>"
idx = content.find(marker)
if idx == -1:
    sys.exit("error: no <title> element found in appcast")
end = content.find("\n", idx)
if end == -1:
    end = idx + len(marker)

insertion_point = end + 1
new_content = content[:insertion_point] + item_xml + "\n" + content[insertion_point:]

with open(path, "w", encoding="utf-8") as f:
    f.write(new_content)
PYEOF

echo "Inserted appcast item: version=${SHORT_VERSION} (sparkle:version=${BUNDLE_VERSION}) into $APPCAST_PATH"
echo "Download URL: ${DOWNLOAD_URL}"
