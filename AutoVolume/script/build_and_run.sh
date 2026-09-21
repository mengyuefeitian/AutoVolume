#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.manual-build"
APP="$ROOT/dist/AutoVolume.app"

cd "$ROOT"

pkill -f "$APP/Contents/MacOS/AutoVolume" 2>/dev/null || true

mkdir -p "$BUILD/shared" "$BUILD/tests" "$ROOT/dist"

swiftc \
  -target arm64-apple-macosx14.0 \
  -enable-testing \
  -emit-module \
  -emit-library \
  -module-name AutoVolumeShared \
  -emit-module-path "$BUILD/shared/AutoVolumeShared.swiftmodule" \
  -Xlinker -install_name \
  -Xlinker @rpath/libAutoVolumeShared.dylib \
  -o "$BUILD/shared/libAutoVolumeShared.dylib" \
  Sources/AutoVolumeShared/Models.swift \
  Sources/AutoVolumeShared/ConfigStore.swift \
  Sources/AutoVolumeShared/CredentialStore.swift \
  Sources/AutoVolumeShared/CommandRunner.swift \
  Sources/AutoVolumeShared/AutoVolumeLogger.swift \
  Sources/AutoVolumeShared/AppSettings.swift \
  Sources/AutoVolumeShared/MountPlanning.swift \
  Sources/AutoVolumeShared/MountExposure.swift \
  Sources/AutoVolumeShared/MountState.swift \
  Sources/AutoVolumeShared/AgentEngine.swift \
  Sources/AutoVolumeShared/CheckScheduler.swift \
  Sources/AutoVolumeShared/ConnectivityTesting.swift \
  Sources/AutoVolumeShared/SMBPreferencesWriter.swift \
  Sources/AutoVolumeShared/AlertStore.swift \
  Sources/AutoVolumeShared/NTFSVolume.swift \
  Sources/AutoVolumeShared/NTFSMountedVolumesStore.swift \
  Sources/AutoVolumeShared/NTFSHelperProtocol.swift \
  Sources/AutoVolumeShared/NTFSMountPlanner.swift \
  Sources/AutoVolumeShared/NTFSDriverInstaller.swift \
  Sources/AutoVolumeShared/NTFSHelperClient.swift \
  Sources/AutoVolumeShared/NTFSRemountDebouncer.swift \
  Sources/AutoVolumeShared/NTFSAutoMountService.swift

swiftc \
  -target arm64-apple-macosx14.0 \
  -I "$BUILD/shared" \
  -L "$BUILD/shared" \
  -lAutoVolumeShared \
  -Xlinker -rpath \
  -Xlinker @executable_path/../shared \
  -o "$BUILD/tests/AutoVolumeManualTests" \
  ManualTests/AutoVolumeManualTests.swift

"$BUILD/tests/AutoVolumeManualTests"

swiftc \
  -target arm64-apple-macosx14.0 \
  -I "$BUILD/shared" \
  -L "$BUILD/shared" \
  -lAutoVolumeShared \
  -framework DiskArbitration \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  -o "$BUILD/AutoVolumeAgent" \
  Sources/AutoVolumeAgent/main.swift

swiftc \
  -target arm64-apple-macosx14.0 \
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
  -target arm64-apple-macosx14.0 \
  -I "$BUILD/shared" \
  -L "$BUILD/shared" \
  -lAutoVolumeShared \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  -o "$BUILD/AutoVolumeApp" \
  Sources/AutoVolumeApp/AutoVolumeApp.swift \
  Sources/AutoVolumeApp/StatusBarController.swift \
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

mkdir -p "$APP/Contents/Resources/NTFSDriver"
cp "$ROOT/Resources/NTFSDriver/ntfs-3g" "$APP/Contents/Resources/NTFSDriver/ntfs-3g"
cp "$ROOT/Resources/NTFSDriver/libntfs-3g.89.dylib" "$APP/Contents/Resources/NTFSDriver/libntfs-3g.89.dylib"
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
codesign --force --sign - "$APP"

if [[ "${1:-}" == "--verify" ]]; then
  plutil -lint "$APP/Contents/Info.plist"
  codesign --verify --deep --strict --verbose=2 "$APP"
  spctl --assess --type execute --verbose=4 "$APP"
fi

if [[ "${1:-}" != "--no-launch" && "${1:-}" != "--verify" ]]; then
  open -n "$APP"
fi
