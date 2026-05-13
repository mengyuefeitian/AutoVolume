# AutoVolume 0.1.20 Release Notes

AutoVolume 0.1.20 is a local test release for the macOS menu bar utility that keeps network volumes mounted and reconnects them after temporary network failures.

## Highlights

- Supports SMB, WebDAV, AFP, and NFS network volumes.
- Supports SMB2-SMB3 auto negotiation and avoids SMB1.
- Supports mounting a nested SMB folder and opening Finder directly to the configured path.
- Adds encrypted local credential storage instead of macOS Keychain dependency.
- Adds in-app alerts instead of disruptive system error dialogs.
- Adds DMG packaging with a drag-to-Applications installer layout.
- Stops the background Agent when the main app quits, while leaving existing mounted volumes untouched.

## Assets

- `AutoVolume-0.1.20-local.dmg`
- `AutoVolume-0.1.20-local.zip`

## Notes

This build is ad-hoc signed for local testing and is not notarized with Developer ID. macOS may show privacy or security prompts on first launch.
