# AutoVolume 0.1.23 Release Notes

AutoVolume 0.1.23 sanitizes public documentation and tests so repository and release assets do not contain local test server details.

## Fixes

- Replaces local test server examples with generic documentation examples.
- Removes a historical redaction-test password fixture from tracked source.
- Keeps the 0.1.22 duplicate Finder window fix.

## Assets

- `AutoVolume-0.1.23-local.dmg`
- `AutoVolume-0.1.23-local.zip`

## Notes

This build is ad-hoc signed for local testing and is not notarized with Developer ID. macOS may show privacy or security prompts on first launch.

---

# AutoVolume 0.1.22 Release Notes

AutoVolume 0.1.22 fixes duplicate Finder windows after a successful mount.

## Fixes

- Opens only one Finder window after mounting or reconnecting a volume.
- Keeps the Finder target behavior from 0.1.21, including opening nested SMB folders directly.

## Assets

- `AutoVolume-0.1.22-local.dmg`
- `AutoVolume-0.1.22-local.zip`

## Notes

This build is ad-hoc signed for local testing and is not notarized with Developer ID. macOS may show privacy or security prompts on first launch.

---

# AutoVolume 0.1.21 Release Notes

AutoVolume 0.1.21 fixes HTTPS WebDAV mounting on macOS by avoiding `mount_webdav` userinfo URLs and using the same AppleScript mounting path as Finder.

## Fixes

- Fixes WebDAV mount failures that showed `Mount failed with exit code 22`.
- Keeps WebDAV credentials out of the URL passed to `mount_webdav`.
- Keeps the existing encrypted local credential storage and password redaction behavior.

## Assets

- `AutoVolume-0.1.21-local.dmg`
- `AutoVolume-0.1.21-local.zip`

## Notes

This build is ad-hoc signed for local testing and is not notarized with Developer ID. macOS may show privacy or security prompts on first launch.

---

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
