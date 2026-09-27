#!/bin/bash
# Builds AutoVolume for a single architecture. Set TARGET_ARCH=x86_64 for the
# Intel release; it defaults to arm64 so existing invocations are unchanged.
#
# Intermediate objects are kept per-arch (.manual-build-$TARGET_ARCH) so an arm64
# and an x86_64 build can both exist on disk at once. The final bundle always
# lands at dist/AutoVolume.app — package it (script/package_dmg.sh) before
# building the other architecture, or use script/release_all.sh which does the
# full build→package sweep for both.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_ARCH="${TARGET_ARCH:-arm64}"
case "$TARGET_ARCH" in
  arm64|x86_64) ;;
  *) echo "error: TARGET_ARCH must be arm64 or x86_64 (got '$TARGET_ARCH')" >&2; exit 1 ;;
esac
export TARGET_ARCH
echo "Building AutoVolume for $TARGET_ARCH"
BUILD="$ROOT/.manual-build-$TARGET_ARCH"
APP="$ROOT/dist/AutoVolume.app"

cd "$ROOT"

# arm64 stays on the historical flat Resources/NTFSDriver layout; x86_64 and any
# future arch keep their driver in a per-arch subdirectory.
if [[ "$TARGET_ARCH" == "arm64" ]]; then
  NTFS_DRIVER_SRC="$ROOT/Resources/NTFSDriver"
else
  NTFS_DRIVER_SRC="$ROOT/Resources/NTFSDriver/$TARGET_ARCH"
fi
for ntfs_binary in "$NTFS_DRIVER_SRC/ntfs-3g" "$NTFS_DRIVER_SRC/libntfs-3g.89.dylib"; do
  if [[ ! -f "$ntfs_binary" ]]; then
    echo "error: missing $ntfs_binary — build it first:" >&2
    echo "  TARGET_ARCH=$TARGET_ARCH script/build_ntfs3g.sh" >&2
    exit 1
  fi
done
if [[ "$(lipo -archs "$NTFS_DRIVER_SRC/ntfs-3g")" != *"$TARGET_ARCH"* ]]; then
  echo "error: $NTFS_DRIVER_SRC/ntfs-3g has no $TARGET_ARCH slice — rebuild the driver for this arch" >&2
  exit 1
fi

# Each arch publishes to its own Sparkle feed so an Intel Mac is never offered
# an arm64 build (and vice versa). appcast.xml remains the arm64 feed to keep
# every pre-existing install upgrading without interruption.
if [[ "$TARGET_ARCH" == "x86_64" ]]; then
  SU_FEED_URL="https://mengyuefeitian.github.io/AutoVolume/appcast-x86_64.xml"
else
  SU_FEED_URL="https://mengyuefeitian.github.io/AutoVolume/appcast.xml"
fi

SPARKLE_XCFW="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
if [[ ! -d "$SPARKLE_XCFW/Sparkle.framework" ]]; then
  swift package resolve
fi
[[ -d "$SPARKLE_XCFW/Sparkle.framework" ]] || { echo "error: Sparkle.framework not found; run swift package resolve" >&2; exit 1; }
SPARKLE_PUBLIC_KEY="$(tr -d '[:space:]' < "$ROOT/Resources/SparklePublicEDKey.txt")"

for shell_test in "$ROOT"/script/tests/test_*.sh; do
  bash "$shell_test"
done

pkill -f "$APP/Contents/MacOS/AutoVolume" 2>/dev/null || true

mkdir -p "$BUILD/shared" "$BUILD/tests" "$ROOT/dist"

swiftc \
  -target "$TARGET_ARCH-apple-macosx14.0" \
  -enable-testing \
  -emit-module \
  -emit-library \
  -module-name AutoVolumeShared \
  -emit-module-path "$BUILD/shared/AutoVolumeShared.swiftmodule" \
  -Xlinker -install_name \
  -Xlinker @rpath/libAutoVolumeShared.dylib \
  -o "$BUILD/shared/libAutoVolumeShared.dylib" \
  Sources/AutoVolumeShared/Localization.swift \
  Sources/AutoVolumeShared/Localization+Tables.swift \
  Sources/AutoVolumeShared/Models.swift \
  Sources/AutoVolumeShared/ConfigStore.swift \
  Sources/AutoVolumeShared/CredentialStore.swift \
  Sources/AutoVolumeShared/CommandRunner.swift \
  Sources/AutoVolumeShared/AutoVolumeLogger.swift \
  Sources/AutoVolumeShared/DiagnosticsContext.swift \
  Sources/AutoVolumeShared/MainThreadPingPong.swift \
  Sources/AutoVolumeShared/DiagnosticsExporter.swift \
  Sources/AutoVolumeShared/AppSettings.swift \
  Sources/AutoVolumeShared/MountPlanning.swift \
  Sources/AutoVolumeShared/MountExposure.swift \
  Sources/AutoVolumeShared/MountState.swift \
  Sources/AutoVolumeShared/AgentEngine.swift \
  Sources/AutoVolumeShared/CheckScheduler.swift \
  Sources/AutoVolumeShared/ConnectivityTesting.swift \
  Sources/AutoVolumeShared/ServerHostSet.swift \
  Sources/AutoVolumeShared/ManagedMountPoints.swift \
  Sources/AutoVolumeShared/SMBPreferencesWriter.swift \
  Sources/AutoVolumeShared/AlertStore.swift \
  Sources/AutoVolumeShared/NTFSVolume.swift \
  Sources/AutoVolumeShared/NTFSMountedVolumesStore.swift \
  Sources/AutoVolumeShared/NTFSHelperProtocol.swift \
  Sources/AutoVolumeShared/NTFSMountPlanner.swift \
  Sources/AutoVolumeShared/NTFSDriverInstaller.swift \
  Sources/AutoVolumeShared/NTFSHelperClient.swift \
  Sources/AutoVolumeShared/NTFSRemountDebouncer.swift \
  Sources/AutoVolumeShared/NTFSAutoMountService.swift \
  Sources/AutoVolumeShared/UpdateSchedule.swift

swiftc \
  -target "$TARGET_ARCH-apple-macosx14.0" \
  -I "$BUILD/shared" \
  -L "$BUILD/shared" \
  -lAutoVolumeShared \
  -Xlinker -rpath \
  -Xlinker @executable_path/../shared \
  -o "$BUILD/tests/AutoVolumeManualTests" \
  ManualTests/AutoVolumeManualTests.swift

"$BUILD/tests/AutoVolumeManualTests"

swiftc \
  -target "$TARGET_ARCH-apple-macosx14.0" \
  -I "$BUILD/shared" \
  -L "$BUILD/shared" \
  -lAutoVolumeShared \
  -framework DiskArbitration \
  -framework Network \
  -framework SystemConfiguration \
  -framework AppKit \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  -o "$BUILD/AutoVolumeAgent" \
  Sources/AutoVolumeAgent/NetworkPathWatcher.swift \
  Sources/AutoVolumeAgent/ServerReachabilityWatcher.swift \
  Sources/AutoVolumeAgent/MountedVolumeWatcher.swift \
  Sources/AutoVolumeAgent/ScreenUnlockWatcher.swift \
  Sources/AutoVolumeAgent/main.swift

swiftc \
  -target "$TARGET_ARCH-apple-macosx14.0" \
  -I "$BUILD/shared" \
  -L "$BUILD/shared" \
  -lAutoVolumeShared \
  -framework SystemConfiguration \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  -Xlinker -rpath \
  -Xlinker /Library/PrivilegedHelperTools/com.autovolume.ntfsdriver \
  -o "$BUILD/NTFSPrivilegedHelper" \
  Sources/AutoVolumeNTFSHelper/main.swift

swiftc \
  -target "$TARGET_ARCH-apple-macosx14.0" \
  -I "$BUILD/shared" \
  -L "$BUILD/shared" \
  -lAutoVolumeShared \
  -F "$SPARKLE_XCFW" \
  -framework Sparkle \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  -o "$BUILD/AutoVolumeApp" \
  Sources/AutoVolumeApp/AutoVolumeApp.swift \
  Sources/AutoVolumeApp/BundleLocalizationOverride.swift \
  Sources/AutoVolumeApp/MainThreadStallWatchdog.swift \
  Sources/AutoVolumeApp/StatusBarController.swift \
  Sources/AutoVolumeApp/UpdateService.swift \
  Sources/AutoVolumeApp/LaunchAgentInstaller.swift \
  Sources/AutoVolumeApp/AppViewModel.swift \
  Sources/AutoVolumeApp/ContentView.swift \
  Sources/AutoVolumeApp/VolumeEditorView.swift \
  Sources/AutoVolumeApp/SettingsView.swift

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BUILD/AutoVolumeApp" "$APP/Contents/MacOS/AutoVolume"
cp "$BUILD/AutoVolumeAgent" "$APP/Contents/Resources/AutoVolumeAgent"
cp "$BUILD/shared/libAutoVolumeShared.dylib" "$APP/Contents/Frameworks/libAutoVolumeShared.dylib"
cp "$ROOT/Resources/com.autovolume.agent.plist" "$APP/Contents/Resources/com.autovolume.agent.plist"
cp "$ROOT/Resources/AutoVolume.icns" "$APP/Contents/Resources/AutoVolume.icns"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SU_FEED_URL" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUScheduledCheckInterval integer 86400" "$APP/Contents/Info.plist"

ditto "$SPARKLE_XCFW/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

mkdir -p "$APP/Contents/Resources/NTFSDriver"
cp "$NTFS_DRIVER_SRC/ntfs-3g" "$APP/Contents/Resources/NTFSDriver/ntfs-3g"
cp "$NTFS_DRIVER_SRC/libntfs-3g.89.dylib" "$APP/Contents/Resources/NTFSDriver/libntfs-3g.89.dylib"
cp "$ROOT/Resources/NTFSDriver/fuse-t-installer.pkg" "$APP/Contents/Resources/NTFSDriver/fuse-t-installer.pkg"
cp "$ROOT/Resources/NTFSDriver/LICENSE-ntfs-3g.txt" "$APP/Contents/Resources/NTFSDriver/LICENSE-ntfs-3g.txt"
cp "$ROOT/Resources/NTFSDriver/LICENSE-fuse-t.txt" "$APP/Contents/Resources/NTFSDriver/LICENSE-fuse-t.txt"
chmod +x "$APP/Contents/Resources/NTFSDriver/ntfs-3g"
cp "$BUILD/NTFSPrivilegedHelper" "$APP/Contents/Resources/NTFSPrivilegedHelper"
cp "$ROOT/Resources/com.autovolume.ntfshelper.plist" "$APP/Contents/Resources/com.autovolume.ntfshelper.plist"
cp "$ROOT/Resources/com.autovolume.ntfshelper.newsyslog.conf" "$APP/Contents/Resources/com.autovolume.ntfshelper.newsyslog.conf"

codesign --force --sign - "$APP/Contents/Frameworks/libAutoVolumeShared.dylib"
codesign --force --sign - "$APP/Contents/Resources/AutoVolumeAgent"
codesign --force --sign - "$APP/Contents/Resources/NTFSDriver/ntfs-3g"
codesign --force --sign - "$APP/Contents/Resources/NTFSPrivilegedHelper"

codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework"

codesign --force --sign - "$APP"

"$ROOT/script/check_binary_compat.sh" "$APP"

if [[ "${1:-}" == "--verify" ]]; then
  plutil -lint "$APP/Contents/Info.plist"
  codesign --verify --deep --strict --verbose=2 "$APP"
  spctl --assess --type execute --verbose=4 "$APP"
fi

if [[ "${1:-}" != "--no-launch" && "${1:-}" != "--verify" ]]; then
  open -n "$APP"
fi
