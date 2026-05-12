#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.manual-build"
APP="$ROOT/dist/AutoVolume.app"

cd "$ROOT"

pkill -f "$APP/Contents/MacOS/AutoVolume" 2>/dev/null || true

mkdir -p "$BUILD/shared" "$BUILD/tests" "$ROOT/dist"

swiftc \
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
  Sources/AutoVolumeShared/MountPlanning.swift \
  Sources/AutoVolumeShared/MountState.swift \
  Sources/AutoVolumeShared/AgentEngine.swift \
  Sources/AutoVolumeShared/CheckScheduler.swift

swiftc \
  -I "$BUILD/shared" \
  -L "$BUILD/shared" \
  -lAutoVolumeShared \
  -Xlinker -rpath \
  -Xlinker @executable_path/../shared \
  -o "$BUILD/tests/AutoVolumeManualTests" \
  ManualTests/AutoVolumeManualTests.swift

"$BUILD/tests/AutoVolumeManualTests"

swiftc \
  -I "$BUILD/shared" \
  -L "$BUILD/shared" \
  -lAutoVolumeShared \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  -o "$BUILD/AutoVolumeAgent" \
  Sources/AutoVolumeAgent/main.swift

swiftc \
  -I "$BUILD/shared" \
  -L "$BUILD/shared" \
  -lAutoVolumeShared \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  -o "$BUILD/AutoVolumeApp" \
  Sources/AutoVolumeApp/AutoVolumeApp.swift \
  Sources/AutoVolumeApp/AppViewModel.swift \
  Sources/AutoVolumeApp/ContentView.swift \
  Sources/AutoVolumeApp/VolumeEditorView.swift

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BUILD/AutoVolumeApp" "$APP/Contents/MacOS/AutoVolume"
cp "$BUILD/AutoVolumeAgent" "$APP/Contents/Resources/AutoVolumeAgent"
cp "$BUILD/shared/libAutoVolumeShared.dylib" "$APP/Contents/Frameworks/libAutoVolumeShared.dylib"
cp "$ROOT/Resources/com.autovolume.agent.plist" "$APP/Contents/Resources/com.autovolume.agent.plist"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

codesign --force --sign - "$APP/Contents/Frameworks/libAutoVolumeShared.dylib"
codesign --force --sign - "$APP/Contents/Resources/AutoVolumeAgent"
codesign --force --sign - "$APP"

if [[ "${1:-}" == "--verify" ]]; then
  plutil -lint "$APP/Contents/Info.plist"
  codesign --verify --deep --strict --verbose=2 "$APP"
  spctl --assess --type execute --verbose=4 "$APP"
fi

if [[ "${1:-}" != "--no-launch" && "${1:-}" != "--verify" ]]; then
  open -n "$APP"
fi
