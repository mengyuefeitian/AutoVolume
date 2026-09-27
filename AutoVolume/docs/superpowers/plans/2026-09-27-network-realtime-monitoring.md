# 网络卷实时监控 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace pure polling for network volume (SMB/WebDAV/AFP/NFS) health detection with event-driven, near-real-time detection of disconnect/reconnect, mirroring the existing NTFS DiskArbitration real-time pattern, while keeping the existing 60s polling loop as a slow fallback.

**Architecture:** Three OS-level event sources (`NWPathMonitor` for local network path changes, per-server `SCNetworkReachability` for remote host reachability changes, `NSWorkspace` unmount notifications for OS-forced unmounts) all funnel into a single `checkVolumesNow(reason:)` entry point in `AutoVolumeAgent`, which reuses the existing `AgentEngine.check`/`reconnect` mount logic unchanged — only the trigger timing changes, never the mount/reconnect logic itself.

**Tech Stack:** Swift, `Network` framework (`NWPathMonitor`), `SystemConfiguration` framework (`SCNetworkReachability`), `AppKit` (`NSWorkspace`), existing `AutoVolumeShared`/`AutoVolumeAgent` targets, manual test suite (`ManualTests/AutoVolumeManualTests.swift`, no XCTest — see `AutoVolume/CLAUDE.md`).

**Spec:** `AutoVolume/docs/superpowers/specs/2026-09-27-network-realtime-monitoring-design.md`

## Global Constraints

- Build/test every task with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0` prefixed to `script/build_and_run.sh` — the default SDK 27.0 toolchain fails to compile any multi-file target importing Foundation (see `AutoVolume/CLAUDE.md`).
- `script/build_and_run.sh --no-launch` must pass (all manual tests green) before every commit in this plan.
- New pure/testable logic goes in `Sources/AutoVolumeShared/`, tested via `ManualTests/AutoVolumeManualTests.swift` (`try expect(...)` style, registered in the `tests` array at the bottom of that file) — do not introduce XCTest; it doesn't compile in this project's SDK setup.
- OS-API glue (anything calling `NWPathMonitor`, `SCNetworkReachability`, `NSWorkspace`) goes in `Sources/AutoVolumeAgent/` and is not unit tested, matching the existing precedent of `startNTFSDiskWatcher()` in `Sources/AutoVolumeAgent/main.swift` (also untested glue around `DiskArbitration`). Push all business logic these call into already-tested or newly-tested `AutoVolumeShared` functions.
- Do not modify `AgentEngine`, `MountPlanner`, `ConnectivityTester`, or `CheckScheduler` — this plan only changes when they get called, never their internals.
- Per `AutoVolume/CLAUDE.md`'s release rule: only the final task in this plan bumps the version number and packages a DMG. Earlier tasks just build and run the manual test suite (no version bump, no DMG) — they are intermediate commits, not builds handed to the user.
- No new third-party dependencies. `Network`, `SystemConfiguration`, and `AppKit` are all Apple system frameworks already available to link against (`SystemConfiguration` is already linked for the `NTFSPrivilegedHelper` target in `script/build_and_run.sh`).

## Review Focus

- **SMB share mounted via a subpath**: the visible `config.mountPoint` is a *symlink* into a `.AutoVolumeBacking/<uuid>` backing directory (see `MountExposure.expose`); the OS actually mounts the filesystem at the backing directory, not at `config.mountPoint`. A naive "is this unmount notification about one of our mount points" check that compares against `config.mountPoint` directly would never match for this case, silently disabling real-time unmount detection for exactly the volumes that use this feature. Covered by Task 2's `ManagedMountPoints` test.
- **Multiple volumes sharing one server**: the sample config in this repo already has two volumes (`synology`, `home`) pointing at the same WebDAV host. Registering two separate `SCNetworkReachability` refs for the same hostname would be wasteful and could double-fire; the host set must be deduplicated. Covered by Task 1's `ServerHostSet` test.
- **Disabled volumes must not get real-time monitoring**: a disabled volume shouldn't hold an `SCNetworkReachability` registration or count toward "managed mount points" — otherwise toggling a volume off wouldn't actually stop AutoVolume from reacting to it. Covered by both Task 1 and Task 2 tests.
- **Overlapping/bursty triggers**: `SCNetworkReachabilityGetFlags` is read once immediately for every newly-registered host (so an already-down host is reflected without waiting for a transition), and `NWPathMonitor`/`NSWorkspace` notifications can also fire close together (e.g. network flapping). Concurrent check passes must not stack. This is `main.swift`-only orchestration logic (not unit-testable per this project's existing boundary — `runOnce()` itself has never had a unit test); Task 3 implements the coalescing guard (`isCheckingVolumes`/`checkVolumesAgainAfter`) and Task 7's manual verification step explicitly exercises it (rapid Wi-Fi toggle).
- **Agent session inactive** (`appSessionIsActive() == false`, i.e. the main app has quit): an event-triggered check must not perform the periodic path's "clean up LaunchAgent and `exit(0)`" side effect — that must stay exclusive to the polling path, otherwise a stray network event arriving during/after app quit could exit the agent process in the middle of an unrelated code path or double-run cleanup. Task 3 keeps this branch conditioned on `bypassSchedule == false`; verified by code inspection in that task's review (not automatable — same untested-glue boundary as above).

---

## Task 1: `ServerHostSet` — dedup server hostnames for reachability monitoring

**Files:**
- Modify: `Sources/AutoVolumeShared/ConnectivityTesting.swift:119` (change `hostOnly` from `private` to internal)
- Create: `Sources/AutoVolumeShared/ServerHostSet.swift`
- Test: `ManualTests/AutoVolumeManualTests.swift`

**Interfaces:**
- Produces: `public enum ServerHostSet { public static func hosts(for configs: [VolumeConfig]) -> Set<String> }` — used by Task 5's `ServerReachabilityWatcher.sync(hosts:onChange:)`.

- [ ] **Step 1: Write the failing test**

Add to `ManualTests/AutoVolumeManualTests.swift`, right after `testAutoVolumeLoggerWriteStaysFastAsLogGrowsOverDays` (or any existing test — exact position doesn't matter, just keep it inside the file):

```swift
func testServerHostSetDedupesByHostnameAndSkipsDisabled() throws {
    let enabledA = VolumeConfig(name: "A", protocolType: .webdav, server: "https://nas.example.com:5006", remotePath: "a", username: nil, mountPoint: "/tmp/a-\(UUID().uuidString)", checkIntervalSeconds: 300, isEnabled: true)
    let enabledB = VolumeConfig(name: "B", protocolType: .webdav, server: "https://nas.example.com:5006", remotePath: "b", username: nil, mountPoint: "/tmp/b-\(UUID().uuidString)", checkIntervalSeconds: 300, isEnabled: true)
    let disabled = VolumeConfig(name: "C", protocolType: .smb, server: "other.example.com", remotePath: "c", username: nil, mountPoint: "/tmp/c-\(UUID().uuidString)", checkIntervalSeconds: 300, isEnabled: false)
    let smb = VolumeConfig(name: "D", protocolType: .smb, server: "smb.example.com", remotePath: "d", username: nil, mountPoint: "/tmp/d-\(UUID().uuidString)", checkIntervalSeconds: 300, isEnabled: true)

    let hosts = ServerHostSet.hosts(for: [enabledA, enabledB, disabled, smb])

    try expect(hosts == Set(["nas.example.com", "smb.example.com"]), "expected deduped, enabled-only hostnames, got \(hosts)")
}
```

Register it in the `tests` array near the bottom of the same file, next to the other logger/connectivity-adjacent tests:

```swift
    ("ServerHostSet dedupes by hostname and skips disabled", testServerHostSetDedupesByHostnameAndSkipsDisabled),
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AutoVolume && SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: compile error — `ServerHostSet` does not exist yet.

- [ ] **Step 3: Make `hostOnly` internally shareable**

In `Sources/AutoVolumeShared/ConnectivityTesting.swift`, find:

```swift
    private func hostOnly(_ server: String) -> String {
```

Replace with (drop `private` — default access is `internal`, which is exactly enough for another file in the same `AutoVolumeShared` module to call it; it must not become `public`, since it's not meant to be called from other targets):

```swift
    func hostOnly(_ server: String) -> String {
```

- [ ] **Step 4: Create `ServerHostSet.swift`**

Create `Sources/AutoVolumeShared/ServerHostSet.swift`:

```swift
import Foundation

/// Pure computation of which distinct server hostnames need real-time reachability
/// monitoring, given the current volume list. Used by `ServerReachabilityWatcher` (in the
/// AutoVolumeAgent target) to know which hosts to register `SCNetworkReachability` callbacks
/// for. Kept here, dependency-free, so it's unit testable without any system API glue.
public enum ServerHostSet {
    public static func hosts(for configs: [VolumeConfig]) -> Set<String> {
        let tester = ConnectivityTester()
        var hosts = Set<String>()
        for config in configs where config.isEnabled {
            let host = tester.hostOnly(config.server)
            guard !host.isEmpty else { continue }
            hosts.insert(host)
        }
        return hosts
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd AutoVolume && SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: `All manual tests passed (N)` including `PASS: ServerHostSet dedupes by hostname and skips disabled`.

- [ ] **Step 6: Commit**

```bash
cd /Users/xiaoan/Documents/Playground
git add AutoVolume/Sources/AutoVolumeShared/ConnectivityTesting.swift AutoVolume/Sources/AutoVolumeShared/ServerHostSet.swift AutoVolume/ManualTests/AutoVolumeManualTests.swift
git commit -m "feat: add ServerHostSet for deduped per-server reachability monitoring"
```

---

## Task 2: `ManagedMountPoints` — real live mount paths AutoVolume manages

**Files:**
- Create: `Sources/AutoVolumeShared/ManagedMountPoints.swift`
- Test: `ManualTests/AutoVolumeManualTests.swift`

**Interfaces:**
- Consumes: `MountPlanner.unmountTarget(for: VolumeConfig) -> String` (existing, unchanged), `MountPlanner.effectiveMountPoint(for: VolumeConfig) -> String` (existing, unchanged).
- Produces: `public enum ManagedMountPoints { public static func paths(for configs: [VolumeConfig], planner: MountPlanner = MountPlanner()) -> Set<String> }` — used by Task 6's `MountedVolumeWatcher`.

- [ ] **Step 1: Write the failing test**

Add to `ManualTests/AutoVolumeManualTests.swift`:

```swift
func testManagedMountPointsUsesBackingDirectoryForSMBWithSubpath() throws {
    let smbWithSubpath = VolumeConfig(name: "Share", protocolType: .smb, server: "nas.local", remotePath: "share/subdir", username: nil, mountPoint: "/tmp/mount-point-\(UUID().uuidString)", checkIntervalSeconds: 300, isEnabled: true)
    let webdav = VolumeConfig(name: "WebDAV", protocolType: .webdav, server: "nas.local", remotePath: "docs", username: nil, mountPoint: "/tmp/webdav-\(UUID().uuidString)", checkIntervalSeconds: 300, isEnabled: true)
    let disabled = VolumeConfig(name: "Off", protocolType: .webdav, server: "nas.local", remotePath: "off", username: nil, mountPoint: "/tmp/off-\(UUID().uuidString)", checkIntervalSeconds: 300, isEnabled: false)

    let planner = MountPlanner()
    let paths = ManagedMountPoints.paths(for: [smbWithSubpath, webdav, disabled], planner: planner)

    try expect(!paths.contains(smbWithSubpath.mountPoint), "SMB-with-subpath's symlink path must not be treated as the real mount point")
    try expect(paths.contains(planner.effectiveMountPoint(for: smbWithSubpath)), "must use the real backing directory for SMB-with-subpath")
    try expect(paths.contains(webdav.mountPoint), "webdav has no symlink indirection, so its configured mountPoint IS the real mount point")
    try expect(paths.count == 2, "disabled volume must be excluded, got \(paths)")
}
```

Register it in the `tests` array:

```swift
    ("ManagedMountPoints uses backing directory for SMB with subpath", testManagedMountPointsUsesBackingDirectoryForSMBWithSubpath),
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AutoVolume && SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: compile error — `ManagedMountPoints` does not exist yet.

- [ ] **Step 3: Create `ManagedMountPoints.swift`**

Create `Sources/AutoVolumeShared/ManagedMountPoints.swift`:

```swift
import Foundation

/// Pure computation of the real, live filesystem mount points AutoVolume manages, given the
/// current volume list. Used by `MountedVolumeWatcher` (in the AutoVolumeAgent target) to
/// decide whether an OS unmount notification is about one of our volumes.
///
/// Deliberately reuses `MountPlanner.unmountTarget(for:)` rather than `config.mountPoint`
/// directly: for an SMB share with a subpath, the volume is actually mounted at a
/// `.AutoVolumeBacking/<uuid>` backing directory and `config.mountPoint` is just a symlink
/// into it (see `MountExposure.expose`), so comparing against `config.mountPoint` would
/// silently never match and real-time unmount detection would never fire for that volume.
public enum ManagedMountPoints {
    public static func paths(for configs: [VolumeConfig], planner: MountPlanner = MountPlanner()) -> Set<String> {
        Set(configs.filter { $0.isEnabled }.map { planner.unmountTarget(for: $0) })
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AutoVolume && SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: `All manual tests passed (N)` including `PASS: ManagedMountPoints uses backing directory for SMB with subpath`.

- [ ] **Step 5: Commit**

```bash
cd /Users/xiaoan/Documents/Playground
git add AutoVolume/Sources/AutoVolumeShared/ManagedMountPoints.swift AutoVolume/ManualTests/AutoVolumeManualTests.swift
git commit -m "feat: add ManagedMountPoints for correct live-mount-path matching"
```

---

## Task 3: Refactor `AutoVolumeAgent/main.swift` to separate "what to check" from "when"

This task changes **only** the trigger plumbing in `main.swift`; the per-volume check/reconnect/alert body is copied verbatim (not modified) into a new function. No new watcher is wired up yet — that happens in Tasks 4–6. This keeps this task's diff small and its behavior change verifiable by inspection: the polling path (`runOnce()`) must do exactly what it did before.

**Files:**
- Modify: `Sources/AutoVolumeAgent/main.swift:22-30` (add coalescing state), `Sources/AutoVolumeAgent/main.swift:106-179` (replace `runOnce()` with `checkVolumes`/`runCheckCycle`/`runOnce`/`checkVolumesNow`)

**Interfaces:**
- Produces: `func checkVolumesNow(reason: String)` (top-level in `main.swift`) — called by Task 4's `NetworkPathWatcher`, Task 5's `ServerReachabilityWatcher`, and Task 6's `MountedVolumeWatcher`.
- Consumes: nothing new — all existing globals (`store`, `scheduler`, `engine`, `mountStateProvider`, `mountPlanner`, `alertStore`, `networkFailedVolumeIDs`, `credentialStore`, `connectivityTester`) stay exactly as declared.

- [ ] **Step 1: Add coalescing state next to the existing globals**

In `Sources/AutoVolumeAgent/main.swift`, find (around line 25):

```swift
var networkFailedVolumeIDs = Set<UUID>()
```

Replace with:

```swift
var networkFailedVolumeIDs = Set<UUID>()
/// Guards `runCheckCycle` against overlapping runs: the periodic 60s timer and the real-time
/// watchers added in later tasks all funnel through the same entry point, and a check pass can
/// take several seconds (each unreachable volume's connectivity test has its own multi-second
/// timeout). If a trigger arrives while a pass is already running, it's recorded here instead
/// of starting a second concurrent pass; the in-flight pass re-runs once more immediately after
/// finishing if this is set, so nothing is silently dropped.
var isCheckingVolumes = false
var checkVolumesAgainAfter = false
```

- [ ] **Step 2: Run the existing manual tests to confirm the baseline still builds**

Run: `cd AutoVolume && SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: `All manual tests passed (N)` — the Agent target doesn't get exercised by `ManualTests` directly (it's a separate executable target), so this just confirms nothing else broke. The real check for this task is Step 4 below.

- [ ] **Step 3: Replace `runOnce()` with `checkVolumes` / `runCheckCycle` / `runOnce` / `checkVolumesNow`**

In `Sources/AutoVolumeAgent/main.swift`, find the entire existing `runOnce()` function (currently lines 106–179):

```swift
func runOnce() {
    guard appSessionIsActive() else {
        AutoVolumeLogger.shared.info("Agent session is inactive; cleaning up")
        cleanupOrphanedLaunchAgent()
        exit(0)
    }

    let configs: [VolumeConfig]
    do {
        configs = try store.load()
    } catch {
        AutoVolumeLogger.shared.error("Agent config load error: \(error.localizedDescription)")
        fputs("AutoVolumeAgent config error: \(error)\n", stderr)
        return
    }

    let now = Date()
    for config in configs where config.isEnabled {
        guard scheduler.isDue(volumeID: config.id, interval: config.checkIntervalSeconds, now: now) else {
            continue
        }

        do {
            let connectivity = try serverReachability(config)
            guard connectivity.isReachable else {
                networkFailedVolumeIDs.insert(config.id)
                scheduler.markChecked(volumeID: config.id, at: retryCheckedDate(interval: config.checkIntervalSeconds, retryInterval: 60, now: now))
                AutoVolumeLogger.shared.warning("Server is not reachable for \(config.name): \(connectivity.message ?? "network unavailable")")
                if let key = connectivity.messageKey {
                    try? alertStore.record(volumeID: config.id, volumeName: config.name, key: key, args: connectivity.messageArgs, date: now)
                } else {
                    try? alertStore.record(volumeID: config.id, volumeName: config.name, message: connectivity.message ?? "Server is not reachable. AutoVolume will retry after the network returns.", date: now)
                }
                continue
            }

            let status: VolumeStatus
            let wasMounted = mountStateProvider.isMounted(config: config)
            if networkFailedVolumeIDs.contains(config.id) {
                status = try engine.reconnect(config)
                if status == .mounted {
                    openMountedVolume(config)
                }
            } else {
                status = try engine.check(config)
                if !wasMounted, status == .mounted, mountPlanner.shouldOpenFinderAfterMount(for: config) {
                    openMountedVolume(config)
                }
            }
            scheduler.markChecked(volumeID: config.id, at: checkedDate(for: status, interval: config.checkIntervalSeconds, now: now))
            switch status {
            case .mounted:
                networkFailedVolumeIDs.remove(config.id)
                try? alertStore.resolve(volumeID: config.id)
                AutoVolumeLogger.shared.info("Agent check mounted for \(config.name)")
            case .failed(let message, let key, let args):
                if let key {
                    try? alertStore.record(volumeID: config.id, volumeName: config.name, key: L10nKey(rawValue: key), args: args, date: now)
                } else {
                    try? alertStore.record(volumeID: config.id, volumeName: config.name, message: message, date: now)
                }
                AutoVolumeLogger.shared.warning("Agent check failed for \(config.name): \(message)")
            case .unmounted, .checking:
                break
            }
        } catch {
            scheduler.markChecked(volumeID: config.id, at: checkedDate(for: error, interval: config.checkIntervalSeconds, now: now))
            let message = CommandResult.redacted(error.localizedDescription)
            try? alertStore.record(volumeID: config.id, volumeName: config.name, message: message, date: now)
            AutoVolumeLogger.shared.error("Agent mount error for \(config.name): \(message)")
            fputs("AutoVolumeAgent mount error for \(config.name): \(message)\n", stderr)
        }
    }
}
```

Replace the whole thing with:

```swift
/// The actual per-volume check/reconnect/alert body, unchanged from the original `runOnce()`
/// except for the `bypassSchedule` guard added below. Called by both the periodic timer path
/// and the real-time event-triggered path (Tasks 4–6) — everything downstream of this function
/// (AgentEngine, MountPlanner, ConnectivityTester, alerts) is identical either way; only whether
/// `CheckScheduler.isDue` gates each volume differs.
func checkVolumes(configs: [VolumeConfig], now: Date, bypassSchedule: Bool) {
    for config in configs where config.isEnabled {
        if !bypassSchedule {
            guard scheduler.isDue(volumeID: config.id, interval: config.checkIntervalSeconds, now: now) else {
                continue
            }
        }

        do {
            let connectivity = try serverReachability(config)
            guard connectivity.isReachable else {
                networkFailedVolumeIDs.insert(config.id)
                scheduler.markChecked(volumeID: config.id, at: retryCheckedDate(interval: config.checkIntervalSeconds, retryInterval: 60, now: now))
                AutoVolumeLogger.shared.warning("Server is not reachable for \(config.name): \(connectivity.message ?? "network unavailable")")
                if let key = connectivity.messageKey {
                    try? alertStore.record(volumeID: config.id, volumeName: config.name, key: key, args: connectivity.messageArgs, date: now)
                } else {
                    try? alertStore.record(volumeID: config.id, volumeName: config.name, message: connectivity.message ?? "Server is not reachable. AutoVolume will retry after the network returns.", date: now)
                }
                continue
            }

            let status: VolumeStatus
            let wasMounted = mountStateProvider.isMounted(config: config)
            if networkFailedVolumeIDs.contains(config.id) {
                status = try engine.reconnect(config)
                if status == .mounted {
                    openMountedVolume(config)
                }
            } else {
                status = try engine.check(config)
                if !wasMounted, status == .mounted, mountPlanner.shouldOpenFinderAfterMount(for: config) {
                    openMountedVolume(config)
                }
            }
            scheduler.markChecked(volumeID: config.id, at: checkedDate(for: status, interval: config.checkIntervalSeconds, now: now))
            switch status {
            case .mounted:
                networkFailedVolumeIDs.remove(config.id)
                try? alertStore.resolve(volumeID: config.id)
                AutoVolumeLogger.shared.info("Agent check mounted for \(config.name)")
            case .failed(let message, let key, let args):
                if let key {
                    try? alertStore.record(volumeID: config.id, volumeName: config.name, key: L10nKey(rawValue: key), args: args, date: now)
                } else {
                    try? alertStore.record(volumeID: config.id, volumeName: config.name, message: message, date: now)
                }
                AutoVolumeLogger.shared.warning("Agent check failed for \(config.name): \(message)")
            case .unmounted, .checking:
                break
            }
        } catch {
            scheduler.markChecked(volumeID: config.id, at: checkedDate(for: error, interval: config.checkIntervalSeconds, now: now))
            let message = CommandResult.redacted(error.localizedDescription)
            try? alertStore.record(volumeID: config.id, volumeName: config.name, message: message, date: now)
            AutoVolumeLogger.shared.error("Agent mount error for \(config.name): \(message)")
            fputs("AutoVolumeAgent mount error for \(config.name): \(message)\n", stderr)
        }
    }
}

/// Loads the current config and runs one `checkVolumes` pass. Also re-syncs which server
/// hosts `serverReachabilityWatcher` (Task 5) should be watching, since the volume list can
/// change between calls (added/edited/removed) and this is the one place both the periodic
/// and real-time paths always pass through.
func performCheckCycle(bypassSchedule: Bool) {
    let configs: [VolumeConfig]
    do {
        configs = try store.load()
    } catch {
        AutoVolumeLogger.shared.error("Agent config load error: \(error.localizedDescription)")
        fputs("AutoVolumeAgent config error: \(error)\n", stderr)
        return
    }
    checkVolumes(configs: configs, now: Date(), bypassSchedule: bypassSchedule)
}

/// Shared entry point for both the periodic timer and the real-time watchers. Coalesces
/// overlapping triggers (see `isCheckingVolumes` above) and reproduces the original
/// `runOnce()`'s session-inactive handling exactly, but *only* on the periodic path
/// (`bypassSchedule == false`) — a stray real-time event must never itself clean up the
/// LaunchAgent and exit the process; that stays exclusive to the periodic tick, matching the
/// original behavior.
func runCheckCycle(bypassSchedule: Bool, reason: String?) {
    guard appSessionIsActive() else {
        if !bypassSchedule {
            AutoVolumeLogger.shared.info("Agent session is inactive; cleaning up")
            cleanupOrphanedLaunchAgent()
            exit(0)
        }
        return
    }

    if isCheckingVolumes {
        checkVolumesAgainAfter = true
        return
    }
    isCheckingVolumes = true
    defer { isCheckingVolumes = false }

    if let reason {
        AutoVolumeLogger.shared.info("Real-time check triggered: \(reason)")
    }

    repeat {
        checkVolumesAgainAfter = false
        performCheckCycle(bypassSchedule: bypassSchedule)
    } while checkVolumesAgainAfter
}

func runOnce() {
    runCheckCycle(bypassSchedule: false, reason: nil)
}

/// Called by the real-time watchers (Tasks 4–6) the moment they observe a change worth
/// reacting to immediately, instead of waiting for the next 60s timer tick. `reason` is a
/// short machine-readable tag (e.g. "network-path-changed") logged so a later read of
/// `AutoVolume.log` can tell a real-time-triggered check apart from a routine poll.
func checkVolumesNow(reason: String) {
    runCheckCycle(bypassSchedule: true, reason: reason)
}
```

- [ ] **Step 4: Build and run manual tests**

Run: `cd AutoVolume && SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: builds cleanly (this compiles `AutoVolumeAgent`, so a `main.swift` mistake would fail the build here), `All manual tests passed (N)`.

- [ ] **Step 5: Commit**

```bash
cd /Users/xiaoan/Documents/Playground
git add AutoVolume/Sources/AutoVolumeAgent/main.swift
git commit -m "refactor: split AutoVolumeAgent's check loop into schedule-gated and immediate paths"
```

---

## Task 4: `NetworkPathWatcher` — react to local network path changes

**Files:**
- Create: `Sources/AutoVolumeAgent/NetworkPathWatcher.swift`
- Modify: `Sources/AutoVolumeAgent/main.swift` (instantiate + start)
- Modify: `script/build_and_run.sh` (add file + `-framework Network` to the Agent build command)

**Interfaces:**
- Produces: `final class NetworkPathWatcher { func start(onChange: @escaping () -> Void); func stop() }`.
- Consumes: calls `checkVolumesNow(reason:)` from Task 3.

- [ ] **Step 1: Create `NetworkPathWatcher.swift`**

Create `Sources/AutoVolumeAgent/NetworkPathWatcher.swift`:

```swift
import Foundation
import Network

/// Wraps `NWPathMonitor` to signal "the local network path changed" — Wi-Fi reconnected,
/// Ethernet plugged in, VPN connected/disconnected, woke from sleep onto a different network,
/// etc. Deliberately does not inspect `NWPath.status`: even a change that still leaves the
/// path unsatisfied is worth an immediate recheck, and an extra recheck against an
/// already-healthy volume is cheap (a local `isMounted` check, no network I/O for volumes that
/// are already fine).
///
/// This is glue directly wrapping a system API and is intentionally not unit tested — see the
/// design doc's Testing Strategy section and this plan's Global Constraints.
final class NetworkPathWatcher {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.autovolume.agent.network-path-watcher")

    func start(onChange: @escaping () -> Void) {
        monitor.pathUpdateHandler = { _ in
            onChange()
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
```

- [ ] **Step 2: Wire it into `main.swift`**

In `Sources/AutoVolumeAgent/main.swift`, find:

```swift
startNTFSDiskWatcher()
```

Replace with:

```swift
startNTFSDiskWatcher()

let networkPathWatcher = NetworkPathWatcher()
networkPathWatcher.start {
    checkVolumesNow(reason: "network-path-changed")
}
```

- [ ] **Step 3: Update the build script**

In `script/build_and_run.sh`, find the `AutoVolumeAgent` build command:

```bash
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
```

Replace with:

```bash
swiftc \
  -target arm64-apple-macosx14.0 \
  -I "$BUILD/shared" \
  -L "$BUILD/shared" \
  -lAutoVolumeShared \
  -framework DiskArbitration \
  -framework Network \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  -o "$BUILD/AutoVolumeAgent" \
  Sources/AutoVolumeAgent/NetworkPathWatcher.swift \
  Sources/AutoVolumeAgent/main.swift
```

- [ ] **Step 4: Build and run manual tests**

Run: `cd AutoVolume && SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: builds cleanly, `All manual tests passed (N)`.

- [ ] **Step 5: Commit**

```bash
cd /Users/xiaoan/Documents/Playground
git add AutoVolume/Sources/AutoVolumeAgent/NetworkPathWatcher.swift AutoVolume/Sources/AutoVolumeAgent/main.swift AutoVolume/script/build_and_run.sh
git commit -m "feat: react to local network path changes in real time"
```

---

## Task 5: `ServerReachabilityWatcher` — react to per-server reachability changes

This is the piece that covers "the NAS itself rebooted/came back, but my laptop's own network never changed" — the scenario `NetworkPathWatcher` alone cannot detect.

**Files:**
- Create: `Sources/AutoVolumeAgent/ServerReachabilityWatcher.swift`
- Modify: `Sources/AutoVolumeAgent/main.swift` (instantiate + call `sync` from `performCheckCycle`)
- Modify: `script/build_and_run.sh` (add file + `-framework SystemConfiguration` to the Agent build command)

**Interfaces:**
- Consumes: `ServerHostSet.hosts(for: [VolumeConfig]) -> Set<String>` from Task 1.
- Produces: `final class ServerReachabilityWatcher { func sync(hosts: Set<String>, onChange: @escaping (String, Bool) -> Void) }`. Calls `checkVolumesNow(reason:)` from Task 3 via the closure `main.swift` passes in.

- [ ] **Step 1: Create `ServerReachabilityWatcher.swift`**

Create `Sources/AutoVolumeAgent/ServerReachabilityWatcher.swift`:

```swift
import Foundation
import SystemConfiguration

/// Wraps `SCNetworkReachability`, one ref per distinct server hostname, to signal "this
/// specific server's reachability just changed" — covers the case where the local network
/// never changed but the remote host did (NAS rebooted, came back online), so
/// `NetworkPathWatcher` alone would never fire.
///
/// This is glue directly wrapping a system API and is intentionally not unit tested — see the
/// design doc's Testing Strategy section and this plan's Global Constraints. The set-difference
/// bookkeeping in `sync` is simple enough (plain `Set` operations) not to need its own
/// extracted, tested helper.
final class ServerReachabilityWatcher {
    /// Bundles a host's `SCNetworkReachability` ref with the host string, so the C callback
    /// (which only receives the ref and an opaque `info` pointer) can report back which host
    /// changed. `watcher` is `weak` to avoid a retain cycle: this object's lifetime is owned by
    /// `registrations`, which is owned by `ServerReachabilityWatcher`.
    private final class Registration {
        let host: String
        let ref: SCNetworkReachability
        weak var watcher: ServerReachabilityWatcher?
        init(host: String, ref: SCNetworkReachability, watcher: ServerReachabilityWatcher) {
            self.host = host
            self.ref = ref
            self.watcher = watcher
        }
    }

    private var registrations: [String: Registration] = [:]
    private let queue = DispatchQueue(label: "com.autovolume.agent.server-reachability-watcher")

    /// Adds reachability monitoring for any host in `hosts` not already watched, and removes
    /// monitoring for any host no longer in `hosts` (its volume was deleted or disabled). Safe
    /// to call repeatedly with the same or a changed set — cheap when nothing changed. `onChange`
    /// is replaced on every call (the closure captures the current `checkVolumesNow`, which
    /// doesn't change, so this is only ever called with an equivalent closure in practice).
    func sync(hosts: Set<String>, onChange: @escaping (String, Bool) -> Void) {
        let currentHosts = Set(registrations.keys)

        for host in currentHosts.subtracting(hosts) {
            if let registration = registrations.removeValue(forKey: host) {
                SCNetworkReachabilitySetCallback(registration.ref, nil, nil)
                SCNetworkReachabilitySetDispatchQueue(registration.ref, nil)
            }
        }

        for host in hosts.subtracting(currentHosts) {
            guard let ref = SCNetworkReachabilityCreateWithName(nil, host) else { continue }
            let registration = Registration(host: host, ref: ref, watcher: self)
            registrations[host] = registration

            let info = Unmanaged.passUnretained(registration).toOpaque()
            var context = SCNetworkReachabilityContext(version: 0, info: info, retain: nil, release: nil, copyDescription: nil)
            let callback: SCNetworkReachabilityCallBack = { _, flags, info in
                guard let info else { return }
                let registration = Unmanaged<Registration>.fromOpaque(info).takeUnretainedValue()
                registration.watcher?.handleFlagsChanged(flags: flags, host: registration.host, onChange: onChange)
            }
            guard SCNetworkReachabilitySetCallback(ref, callback, &context) else { continue }
            SCNetworkReachabilitySetDispatchQueue(ref, queue)

            // The callback above only fires on a *change*. Read the current flags once up
            // front so a host that's already unreachable at the moment it's first registered
            // (e.g. a volume added while the NAS happens to be down) is reflected immediately
            // instead of silently waiting for the next transition.
            var initialFlags = SCNetworkReachabilityFlags()
            if SCNetworkReachabilityGetFlags(ref, &initialFlags) {
                handleFlagsChanged(flags: initialFlags, host: host, onChange: onChange)
            }
        }
    }

    private func handleFlagsChanged(flags: SCNetworkReachabilityFlags, host: String, onChange: (String, Bool) -> Void) {
        let isReachable = flags.contains(.reachable) && !flags.contains(.connectionRequired)
        onChange(host, isReachable)
    }
}
```

- [ ] **Step 2: Wire it into `main.swift`**

In `Sources/AutoVolumeAgent/main.swift`, find:

```swift
let networkPathWatcher = NetworkPathWatcher()
networkPathWatcher.start {
    checkVolumesNow(reason: "network-path-changed")
}
```

Replace with (adds the new watcher alongside the existing one):

```swift
let networkPathWatcher = NetworkPathWatcher()
networkPathWatcher.start {
    checkVolumesNow(reason: "network-path-changed")
}

let serverReachabilityWatcher = ServerReachabilityWatcher()
```

Then find `performCheckCycle` (added in Task 3):

```swift
func performCheckCycle(bypassSchedule: Bool) {
    let configs: [VolumeConfig]
    do {
        configs = try store.load()
    } catch {
        AutoVolumeLogger.shared.error("Agent config load error: \(error.localizedDescription)")
        fputs("AutoVolumeAgent config error: \(error)\n", stderr)
        return
    }
    checkVolumes(configs: configs, now: Date(), bypassSchedule: bypassSchedule)
}
```

Replace with (adds the reachability sync right after loading the current config, so it always reflects the latest volume list):

```swift
func performCheckCycle(bypassSchedule: Bool) {
    let configs: [VolumeConfig]
    do {
        configs = try store.load()
    } catch {
        AutoVolumeLogger.shared.error("Agent config load error: \(error.localizedDescription)")
        fputs("AutoVolumeAgent config error: \(error)\n", stderr)
        return
    }
    serverReachabilityWatcher.sync(hosts: ServerHostSet.hosts(for: configs)) { host, isReachable in
        checkVolumesNow(reason: "server-reachability-changed:\(host):\(isReachable ? "reachable" : "unreachable")")
    }
    checkVolumes(configs: configs, now: Date(), bypassSchedule: bypassSchedule)
}
```

- [ ] **Step 3: Update the build script**

In `script/build_and_run.sh`, find the `AutoVolumeAgent` build command (as updated by Task 4):

```bash
swiftc \
  -target arm64-apple-macosx14.0 \
  -I "$BUILD/shared" \
  -L "$BUILD/shared" \
  -lAutoVolumeShared \
  -framework DiskArbitration \
  -framework Network \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  -o "$BUILD/AutoVolumeAgent" \
  Sources/AutoVolumeAgent/NetworkPathWatcher.swift \
  Sources/AutoVolumeAgent/main.swift
```

Replace with:

```bash
swiftc \
  -target arm64-apple-macosx14.0 \
  -I "$BUILD/shared" \
  -L "$BUILD/shared" \
  -lAutoVolumeShared \
  -framework DiskArbitration \
  -framework Network \
  -framework SystemConfiguration \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  -o "$BUILD/AutoVolumeAgent" \
  Sources/AutoVolumeAgent/NetworkPathWatcher.swift \
  Sources/AutoVolumeAgent/ServerReachabilityWatcher.swift \
  Sources/AutoVolumeAgent/main.swift
```

- [ ] **Step 4: Build and run manual tests**

Run: `cd AutoVolume && SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: builds cleanly, `All manual tests passed (N)`.

- [ ] **Step 5: Commit**

```bash
cd /Users/xiaoan/Documents/Playground
git add AutoVolume/Sources/AutoVolumeAgent/ServerReachabilityWatcher.swift AutoVolume/Sources/AutoVolumeAgent/main.swift AutoVolume/script/build_and_run.sh
git commit -m "feat: react to per-server reachability changes in real time"
```

---

## Task 6: `MountedVolumeWatcher` — react to OS-forced unmounts

**Files:**
- Create: `Sources/AutoVolumeAgent/MountedVolumeWatcher.swift`
- Modify: `Sources/AutoVolumeAgent/main.swift` (instantiate + start)
- Modify: `script/build_and_run.sh` (add file + `-framework AppKit` to the Agent build command)

**Interfaces:**
- Consumes: `ManagedMountPoints.paths(for:planner:) -> Set<String>` from Task 2.
- Produces: `final class MountedVolumeWatcher { func start(managedMountPoints: @escaping () -> Set<String>, onUnmount: @escaping () -> Void) }`. Calls `checkVolumesNow(reason:)` from Task 3 via the closure `main.swift` passes in.

- [ ] **Step 1: Create `MountedVolumeWatcher.swift`**

Create `Sources/AutoVolumeAgent/MountedVolumeWatcher.swift`:

```swift
import Foundation
import AppKit

/// Wraps `NSWorkspace`'s unmount notification to signal "the OS just force-unmounted one of
/// our configured network volumes" — SMB in particular will sometimes unmount a
/// long-unresponsive share on its own, without AutoVolume having done anything. Filters to only
/// the mount points AutoVolume actually manages (via `managedMountPoints`, evaluated fresh on
/// every notification so it always reflects the current volume list) so ejecting an unrelated
/// USB drive doesn't trigger a recheck.
///
/// This is glue directly wrapping a system API and is intentionally not unit tested — see the
/// design doc's Testing Strategy section and this plan's Global Constraints. The filtering logic
/// it depends on (`ManagedMountPoints.paths`) is tested in Task 2.
final class MountedVolumeWatcher {
    private var observer: NSObjectProtocol?

    func start(managedMountPoints: @escaping () -> Set<String>, onUnmount: @escaping () -> Void) {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            guard managedMountPoints().contains(url.path) else { return }
            onUnmount()
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
```

- [ ] **Step 2: Wire it into `main.swift`**

In `Sources/AutoVolumeAgent/main.swift`, find:

```swift
let serverReachabilityWatcher = ServerReachabilityWatcher()
```

Replace with:

```swift
let serverReachabilityWatcher = ServerReachabilityWatcher()

let mountedVolumeWatcher = MountedVolumeWatcher()
mountedVolumeWatcher.start(
    managedMountPoints: {
        ManagedMountPoints.paths(for: (try? store.load()) ?? [], planner: mountPlanner)
    },
    onUnmount: {
        checkVolumesNow(reason: "volume-unmounted")
    }
)
```

- [ ] **Step 3: Update the build script**

In `script/build_and_run.sh`, find the `AutoVolumeAgent` build command (as updated by Task 5):

```bash
swiftc \
  -target arm64-apple-macosx14.0 \
  -I "$BUILD/shared" \
  -L "$BUILD/shared" \
  -lAutoVolumeShared \
  -framework DiskArbitration \
  -framework Network \
  -framework SystemConfiguration \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  -o "$BUILD/AutoVolumeAgent" \
  Sources/AutoVolumeAgent/NetworkPathWatcher.swift \
  Sources/AutoVolumeAgent/ServerReachabilityWatcher.swift \
  Sources/AutoVolumeAgent/main.swift
```

Replace with:

```bash
swiftc \
  -target arm64-apple-macosx14.0 \
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
  Sources/AutoVolumeAgent/main.swift
```

- [ ] **Step 4: Build and run manual tests**

Run: `cd AutoVolume && SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: builds cleanly, `All manual tests passed (N)`.

- [ ] **Step 5: Commit**

```bash
cd /Users/xiaoan/Documents/Playground
git add AutoVolume/Sources/AutoVolumeAgent/MountedVolumeWatcher.swift AutoVolume/Sources/AutoVolumeAgent/main.swift AutoVolume/script/build_and_run.sh
git commit -m "feat: react to OS-forced volume unmounts in real time"
```

---

## Task 7: Release — version bump, manual verification, package DMG

Per `AutoVolume/CLAUDE.md`'s hard release rule, this is the only task in this plan that bumps the version and packages a DMG — every earlier task was an intermediate commit, not a build handed to the user.

**Files:**
- Modify: `Resources/Info.plist` (version bump)

- [ ] **Step 1: Bump the version**

Read `Resources/Info.plist`, find the current `CFBundleShortVersionString`/`CFBundleVersion` pair, and increment both by one patch version (e.g. `0.1.55`/`55` → `0.1.56`/`56` — use whatever the actual current values are at implementation time, they may have moved since this plan was written).

- [ ] **Step 2: Full build and manual test run**

Run: `cd AutoVolume && SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: `All manual tests passed (N)`.

- [ ] **Step 3: Manual real-time verification (cannot be automated — see Review Focus)**

With the built app running (`open dist/AutoVolume.app` or launch from `script/build_and_run.sh` without `--no-launch`) and at least one network volume configured and mounted:

1. **Local network change**: turn Wi-Fi off, wait 2–3 seconds, turn it back on. Tail `~/Library/Application Support/AutoVolume/Logs/AutoVolume.log` and confirm a line containing `Real-time check triggered: network-path-changed` appears within a second or two of Wi-Fi reconnecting, and the volume re-mounts without waiting for the 60s timer.
2. **Remote server change**: power off (or otherwise make unreachable) the configured server while Wi-Fi/Ethernet stays untouched. Confirm a `server-reachability-changed:<host>:unreachable` log line and an alert appear promptly. Power the server back on and confirm `server-reachability-changed:<host>:reachable` appears and the volume re-mounts, again without waiting for the 60s timer.
3. **Burst check**: rapidly toggle Wi-Fi off/on 3–4 times in a row within a few seconds. Confirm the app does not spawn overlapping check passes (no duplicate/garbled log lines from two check passes interleaving) and settles into a correct final mounted/unmounted state — this exercises the `isCheckingVolumes`/`checkVolumesAgainAfter` coalescing from Task 3, which has no automated test.
4. Confirm the existing 60s polling path is unaffected: with networking left untouched, a volume that's already mounted continues to show `Agent check mounted for <name>` roughly once per its configured `checkIntervalSeconds`, same as before this change.

- [ ] **Step 4: Package the DMG**

Run: `cd AutoVolume && SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/package_dmg.sh <version>` (the version from Step 1, e.g. `0.1.56`).

- [ ] **Step 5: Commit**

```bash
cd /Users/xiaoan/Documents/Playground
git add AutoVolume/Resources/Info.plist
git commit -m "release: prepare AutoVolume <version> — real-time network volume monitoring"
```

- [ ] **Step 6: Hand off**

Tell the user the new DMG path (`AutoVolume/dist/AutoVolume-<version>-local.dmg`) and ask them to run through the Step 3 manual verification themselves before this is considered done — build/tests passing doesn't prove the real-time behavior actually works end-to-end on their machine/network.
