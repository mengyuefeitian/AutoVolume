# NetDiskMount 1.0.2 Release Notes

Fixes NFS volumes that could not connect.

- NFS needs the server's full export path (a Synology exports `/volume1/video`, not `video`). The app used to send `/video` and the server answered "Permission denied", which looks like a permissions problem. Entering just a share name now resolves to the exported path automatically (in the editor, and when a saved volume fails to mount), and the corrected path is saved.
- The remote-path help now explains the NFS form, and a failed NFS mount says what to check (path, client IP, non-privileged ports) or why macOS refused the mount point, instead of the raw error.
- NFS mounts use the options that mounted a Synology by hand (`nolocks,noowners,noatime`, 1 MB blocks).

---

# NetDiskMount 1.0.0 Release Notes

AutoVolume is now **NetDiskMount**: the name says what the app does, and the old one was often mistaken for a volume-control tool. This is also the first 1.0 release, with fixes for the problems reported in issues #1, #2 and #3.

## Upgrading

- Installed AutoVolume 0.1.53 or later is offered this build by the built-in updater. Settings, volumes and saved passwords are kept; nothing needs to be re-entered.
- The bundle identifier, data folder and update feed are unchanged on purpose. After an in-app upgrade the app's folder in Applications is still named `AutoVolume.app` (the updater installs over the old path); install from the DMG if you want the file name to change as well.

## Fixes

- **List opens instantly (#3).** The first click after a quiet spell could freeze the window for 5-30 seconds: the first log write after a pause re-parsed an 88,000-line log on the main thread. Log pruning is now O(log n) and the log no longer fills up with routine lines.
- **A share is only "mounted" if it really is that share, at that mount point (#3, #1).** The list used to show an NFS volume as mounted when an SMB mount of the same-named share happened to sit at its path. Mounts are now matched on filesystem, server, share/export and mount point, so failed mounts show as failed and are retried.
- **Stuck mount points are cleared (#2).** A dead mount that blocked the mount point made every check fail with "couldn't be saved in the folder" until a reboot. The blocking mount (and only that one) is now unmounted and the volume re-mounted.
- **Far fewer needless checks (#2).** Network-change events caused by AirDrop/AWDL-style interfaces no longer trigger a full check; the agent logged about 29,000 of them in a week. Changes that matter (a different network, a VPN, going offline) still do.
- **A useful log.** "Agent check mounted" is written once per change instead of on every check, and now says where the volume is mounted.
- **Fresh status on open.** Opening the list refreshes the mount status in the background.

## Naming

- App, menu bar, windows, alerts, installer, update feed title and documentation say NetDiskMount in all five languages. Diagnostics exports are now `NetDiskMount-diagnostics-*.zip`.

---

# AutoVolume 0.1.24 Release Notes

AutoVolume 0.1.24 fixes WebDAV Finder reveal behavior and adds a temporary unmount action in the volume list.

## Fixes

- Prevents WebDAV mounts from opening a second Finder window after macOS already reveals the mounted WebDAV location.
- Keeps SMB and other quiet mounts opening Finder after a successful mount.
- Uses the actual backing mount point when unmounting nested SMB paths.

## Improvements

- Adds an Unmount button to each configured volume row for temporary manual disconnects.
- Keeps automatic reconnect behavior active for enabled records after a manual unmount.

## Assets

- `AutoVolume-0.1.24-local.dmg`
- `AutoVolume-0.1.24-local.zip`

## Notes

This build is ad-hoc signed for local testing and is not notarized with Developer ID. macOS may show privacy or security prompts on first launch.

---

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
