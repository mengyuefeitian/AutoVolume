# AutoVolume（智卷）Design Spec

Date: 2026-05-12
Status: Draft for user review

## Product Summary

AutoVolume（智卷） is a minimalist macOS utility for keeping network volumes mounted. Users add SMB, WebDAV, AFP, or NFS file server connections, configure credentials and a check interval, and the app automatically reconnects a volume when network interruption or system state causes it to become unmounted.

The first release is a reliable mounting MVP. It prioritizes a stable background agent, secure credential storage, and a friendly menu bar control surface over advanced diagnostics or enterprise management features.

## Goals

- Let users add, edit, and remove network volume configurations.
- Support SMB, WebDAV, AFP, and NFS in the first version.
- Store passwords securely in macOS Keychain, never in plain configuration files.
- Periodically check whether enabled volumes are mounted.
- Automatically reconnect enabled volumes when they are missing.
- Mount volumes into macOS Finder-visible locations.
- Provide a polished, light, modern macOS menu bar interface.

## Non-Goals for MVP

- Full log center or historical analytics.
- Import/export of configurations.
- Script hooks before or after mount.
- Team/shared configuration management.
- Network-change-triggered checks.
- A user-facing login item toggle.
- Cross-platform support.

## Architecture

AutoVolume is split into two local components.

### AutoVolume.app

The app is a SwiftUI menu bar utility. It does not need to occupy the Dock by default. It provides a floating panel for configuration and status:

- Volume list with current status.
- Add, edit, and delete volume forms.
- Manual actions: check now, mount now, unmount.
- Friendly error summaries from the agent.

The app writes non-sensitive configuration data to the shared configuration store and writes passwords to Keychain. It can request the agent to refresh state immediately.

### AutoVolumeAgent

AutoVolumeAgent is installed as a user-level LaunchAgent. It runs in the background and performs the actual monitoring work:

- Reads enabled volume configurations.
- Schedules checks according to each volume's interval.
- Detects whether each configured mount point is mounted and accessible.
- Reconnects missing volumes using the matching protocol strategy.
- Writes latest status and error summaries for the app to display.

The LaunchAgent architecture is chosen because the product's core job is background reliability, while the menu bar app is primarily a control surface.

## Shared Storage

Configuration is stored under the user's Application Support directory, for example:

`~/Library/Application Support/AutoVolume/volumes.json`

The file stores only non-sensitive data:

- Volume id
- Display name
- Protocol
- Server
- Remote path
- Username
- Local mount point
- Check interval
- Enabled flag

Passwords are stored in Keychain using the volume id as the stable lookup key. This allows users to edit server addresses or paths without losing the stored password.

## Data Model

```swift
struct VolumeConfig: Codable, Identifiable {
    var id: UUID
    var name: String
    var protocolType: VolumeProtocol
    var server: String
    var remotePath: String
    var username: String?
    var mountPoint: String
    var checkIntervalSeconds: TimeInterval
    var isEnabled: Bool
}

enum VolumeProtocol: String, Codable, CaseIterable {
    case smb
    case webdav
    case afp
    case nfs
}

enum VolumeStatus: Codable, Equatable {
    case mounted
    case unmounted
    case checking
    case failed(message: String)
}
```

## Mount Detection

The agent uses system state as the source of truth:

1. Check that the configured mount point exists.
2. Check whether the mount point appears in mounted volume data, using `FileManager.mountedVolumeURLs` and/or parsed `mount` output.
3. Verify the mount point is accessible enough to distinguish a real mount from a stale directory.

The exact implementation should be wrapped behind a `MountStateProvider` protocol so tests can use fake state.

## Mount and Unmount Strategy

Mount behavior is protocol-specific and hidden behind a `VolumeMounter` abstraction.

- SMB: use standard SMB URL mounting first; keep `mount_smbfs` as an implementation option if direct mounting is needed.
- WebDAV: use standard WebDAV URL mounting first; keep `mount_webdav` as a fallback option.
- AFP: use standard AFP URL mounting first; keep `mount_afp` as a fallback option.
- NFS: use `mount_nfs`; NFS generally does not use a password and requires careful remote export path handling.
- Unmount: use `diskutil unmount` or `umount`, preferring the safer system command behavior.

The implementation should avoid placing passwords directly in process arguments where possible. When a system mount path requires credentials, prefer Keychain-backed macOS authentication flows or protected stdin/configuration mechanisms over command-line secrets.

## Error Handling

Errors are grouped into user-facing categories:

- Authentication failed.
- Network or server unreachable.
- Mount point missing, busy, or invalid.
- Protocol command failed.
- Unknown failure.

The agent stores the latest status and a concise error summary per volume. The MVP does not include a full log browser, but the implementation may write developer-oriented logs using `Logger` for debugging.

Automatic reconnect uses simple throttling: after a failed attempt, the agent waits until the next configured check interval. It does not perform rapid repeated retries in the MVP.

## UI Direction

The interface is a minimalist macOS utility with a light, friendly feel:

- Menu bar entry with an icon-first affordance.
- Floating panel with soft blur or glass-like material.
- Centered main view or clean left-aligned list/detail layout.
- Large rounded primary buttons for clear actions.
- Icon-driven controls for check, mount, unmount, edit, and delete.
- Shortcut hints where they make repeated actions faster.
- Clean high-fidelity visual style inspired by modern macOS utilities.

The UI should remain practical: no landing page, no marketing hero, and no decorative elements that reduce scanability.

## Testing Strategy

Unit tests should cover the logic that can be verified without mounting real network volumes:

- Configuration encoding and decoding.
- Keychain wrapper behavior through a fake or injectable credential store.
- URL or command construction for each protocol.
- Mount status parsing.
- Scheduling interval calculations.
- Agent decision logic for check, reconnect, and failure states.

System command execution should be behind a `CommandRunner` protocol so tests can use fake output and failure modes. Real integration testing against SMB/WebDAV/AFP/NFS servers is outside the MVP automated test suite.

## Implementation Notes

- Start with a Swift package or Xcode project that contains both app and agent targets.
- Keep shared model and storage code in a shared module.
- Keep UI state separate from agent scheduling logic.
- Prefer small, protocol-backed services for Keychain, configuration storage, mount state, command execution, and scheduling.
- Treat LaunchAgent installation and update behavior as part of the product experience, even if the first internal build uses a simple installer helper.

