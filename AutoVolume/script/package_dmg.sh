#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/AutoVolume.app"
VERSION="${1:-0.1.17}"
DMG="$ROOT/dist/AutoVolume-$VERSION-local.dmg"
RW_DMG="$ROOT/dist/AutoVolume-$VERSION-local-rw.dmg"
STAGING="$ROOT/dist/dmg-staging"
MOUNT_POINT="$ROOT/dist/dmg-mount"
BACKGROUND="$STAGING/.background/background.png"
ARROW_SOURCE="/Users/xiaoan/Downloads/拖入.png"

if [[ ! -d "$APP" ]]; then
  echo "Missing app bundle: $APP" >&2
  exit 1
fi

rm -rf "$STAGING" "$MOUNT_POINT" "$RW_DMG" "$DMG"
mkdir -p "$STAGING/.background"
cp -R "$APP" "$STAGING/AutoVolume.app"
/usr/bin/osascript <<APPLESCRIPT >/dev/null
tell application "Finder"
    make new alias file to POSIX file "/Applications" at POSIX file "$STAGING"
end tell
APPLESCRIPT
if [[ -e "$STAGING/应用程序" ]]; then
  mv "$STAGING/应用程序" "$STAGING/Applications"
fi
cleanup() {
  hdiutil detach "/Volumes/AutoVolume" >/dev/null 2>&1 || true
  rm -rf "$STAGING" "$RW_DMG"
}
trap cleanup EXIT

swift - "$BACKGROUND" "$ARROW_SOURCE" <<'SWIFT'
import AppKit

let output = CommandLine.arguments[1]
let arrowSource = CommandLine.arguments[2]
let size = NSSize(width: 640, height: 420)
let image = NSImage(size: size)
image.lockFocus()

NSColor(calibratedRed: 0.94, green: 0.97, blue: 1.0, alpha: 1.0).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

let panel = NSBezierPath(roundedRect: NSRect(x: 28, y: 28, width: 584, height: 364), xRadius: 28, yRadius: 28)
NSColor(calibratedWhite: 1.0, alpha: 0.78).setFill()
panel.fill()

if let arrowImage = NSImage(contentsOfFile: arrowSource) {
    let drawRect = NSRect(x: 270, y: 150, width: 116, height: 116)
    NSGraphicsContext.current?.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: drawRect.midX, yBy: drawRect.midY)
    transform.rotate(byDegrees: 45)
    transform.translateX(by: -drawRect.midX, yBy: -drawRect.midY)
    transform.concat()
    arrowImage.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 0.92)
    NSGraphicsContext.current?.restoreGraphicsState()
} else {
    let arrow = NSBezierPath()
    arrow.lineWidth = 8
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 244, y: 206))
    arrow.curve(to: NSPoint(x: 397, y: 206), controlPoint1: NSPoint(x: 290, y: 260), controlPoint2: NSPoint(x: 350, y: 260))
    arrow.move(to: NSPoint(x: 365, y: 238))
    arrow.line(to: NSPoint(x: 399, y: 206))
    arrow.line(to: NSPoint(x: 358, y: 184))
    NSColor(calibratedRed: 0.14, green: 0.38, blue: 0.78, alpha: 0.88).setStroke()
    arrow.stroke()
}

let title = "拖入应用程序"
let subtitle = "Drag AutoVolume into Applications"
let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 28, weight: .bold),
    .foregroundColor: NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.22, alpha: 1.0)
]
let subtitleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: NSColor(calibratedRed: 0.35, green: 0.42, blue: 0.52, alpha: 1.0)
]
(title as NSString).draw(at: NSPoint(x: 218, y: 322), withAttributes: titleAttributes)
(subtitle as NSString).draw(at: NSPoint(x: 205, y: 294), withAttributes: subtitleAttributes)

let hintAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .regular),
    .foregroundColor: NSColor(calibratedRed: 0.43, green: 0.49, blue: 0.58, alpha: 1.0)
]
if let applicationsIcon = NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns") {
    applicationsIcon.draw(in: NSRect(x: 432, y: 154, width: 96, height: 96), from: .zero, operation: .sourceOver, fraction: 1.0)
}
("AutoVolume" as NSString).draw(at: NSPoint(x: 122, y: 96), withAttributes: hintAttributes)
("Applications" as NSString).draw(at: NSPoint(x: 444, y: 96), withAttributes: hintAttributes)

image.unlockFocus()
guard let data = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: data),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    exit(1)
}
try png.write(to: URL(fileURLWithPath: output))
SWIFT

hdiutil create -volname AutoVolume -srcfolder "$STAGING" -ov -format UDRW -fs HFS+ "$RW_DMG" >/dev/null
attach_output="$(hdiutil attach "$RW_DMG" -readwrite)"
device="$(printf '%s\n' "$attach_output" | awk '/Apple_HFS/ {print $1}')"
volume_path="$(printf '%s\n' "$attach_output" | awk '/Apple_HFS/ {for (i=3; i<=NF; i++) {printf "%s%s", (i==3 ? "" : " "), $i}; print ""}')"
if [[ -z "${volume_path:-}" || ! -d "$volume_path" ]]; then
  volume_path="/Volumes/AutoVolume"
fi

rm -rf "$volume_path/.fseventsd"
chflags hidden "$volume_path/.background" >/dev/null 2>&1 || true
SetFile -a V "$volume_path/.background" >/dev/null 2>&1 || true

osascript <<APPLESCRIPT
tell application "Finder"
    set volumeAlias to POSIX file "$volume_path" as alias
    tell folder volumeAlias
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {120, 120, 760, 540}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set background picture of theViewOptions to file ".background:background.png"
        try
            set position of item "AutoVolume.app" of container window to {160, 210}
        end try
        try
            set position of item "Applications" of container window to {480, 210}
        end try
        try
            set position of item ".background" of container window to {590, 350}
        end try
        try
            set position of item ".fseventsd" of container window to {590, 350}
        end try
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

rm -rf "$volume_path/.fseventsd"
chflags hidden "$volume_path/.background" >/dev/null 2>&1 || true
SetFile -a V "$volume_path/.background" >/dev/null 2>&1 || true
sync
hdiutil detach "$device" >/dev/null
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
hdiutil verify "$DMG"
trap - EXIT
cleanup
echo "$DMG"
