import Foundation
import AutoVolumeShared

enum ManualTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw ManualTestFailure.failed(message)
    }
}

func testVolumeConfigRoundTripsThroughJSON() throws {
    let config = VolumeConfig(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        name: "Design NAS",
        protocolType: .smb,
        server: "files.example.com",
        remotePath: "design",
        username: "xiaoan",
        mountPoint: "/Volumes/Design",
        checkIntervalSeconds: 300,
        isEnabled: true
    )

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(VolumeConfig.self, from: data)

    try expect(decoded == config, "VolumeConfig JSON round trip failed")
}

func testConfigStoreSaveLoadAndMissingFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONConfigStore(directory: directory)

    let missingVolumes = try store.load()
    try expect(missingVolumes == [], "Missing config should load as an empty array")

    let volume = VolumeConfig(
        name: "NAS",
        protocolType: .smb,
        server: "nas.local",
        remotePath: "team",
        username: "mei",
        mountPoint: "/Volumes/Team",
        checkIntervalSeconds: 120,
        isEnabled: true
    )

    try store.save([volume])
    let loadedVolumes = try store.load()
    try expect(loadedVolumes == [volume], "Saved config did not load back")
}

func testInMemoryCredentialStore() throws {
    let store = InMemoryCredentialStore()
    let id = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    try store.savePassword("secret", for: id)
    let savedPassword = try store.password(for: id)
    try expect(savedPassword == "secret", "Password was not saved")

    try store.deletePassword(for: id)
    let deletedPassword = try store.password(for: id)
    try expect(deletedPassword == nil, "Password was not deleted")
}

func testEncryptedFileCredentialStore() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = EncryptedFileCredentialStore(directory: directory)
    let id = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

    try store.savePassword("secret", for: id)
    let savedPassword = try store.password(for: id)
    try expect(savedPassword == "secret", "Encrypted password should round trip")

    let databaseURL = directory.appendingPathComponent("credentials.db")
    let databaseText = try String(contentsOf: databaseURL, encoding: .utf8)
    try expect(!databaseText.contains("secret"), "Encrypted credential database must not store plaintext passwords")

    try store.deletePassword(for: id)
    let deletedPassword = try store.password(for: id)
    try expect(deletedPassword == nil, "Encrypted password should delete")
}

func testCommandResultRedactsPasswords() throws {
    let message = "mount_smbfs: mount error: //user:super-secret@example.test/share: No such file or directory"
    let redacted = CommandResult.redacted(message, secrets: ["super-secret"])
    try expect(!redacted.contains("super-secret"), "Command output should redact raw password")
    try expect(redacted.contains("//user:<redacted>@example.test"), "Command output should preserve useful host context")
}

func testSMBDialectPreferences() throws {
    try expect(SMBDialect.smb2.protocolVersionMap == 2, "SMB2 mode should not allow SMB1")
    try expect(SMBDialect.smb2LargeMTU.protocolVersionMap == 6, "SMB2 + Large MTU mode should allow SMB2 through SMB3")
    try expect(SMBDialect.smb3.protocolVersionMap == 6, "Default SMB mode should auto-negotiate SMB2 through SMB3")
    try expect(SMBDialect.smb3.displayName.contains("SMB2-SMB3"), "Default SMB display should make the auto range clear")
}

func testMountPlanning() throws {
    let smb = VolumeConfig(name: "Team", protocolType: .smb, server: "nas.local", remotePath: "team", username: "mei", mountPoint: "/Volumes/Team", checkIntervalSeconds: 60, isEnabled: true)
    let smbPlan = try MountPlanner().mountPlan(for: smb, password: "secret")
    try expect(smbPlan.executable == "/usr/bin/osascript", "SMB mount should use AppleScript")
    try expect(smbPlan.arguments == ["-"], "SMB mount should pass AppleScript through stdin")
    try expect(smbPlan.standardInput?.contains("smb://nas.local/team") == true, "SMB mount script missing URL")

    let smbNested = VolumeConfig(name: "Video", protocolType: .smb, server: "smb://nas.local/ignored", remotePath: "/video/projects", username: "mei", mountPoint: "/Volumes/Video", checkIntervalSeconds: 60, isEnabled: true)
    let smbNestedPlan = try MountPlanner().mountPlan(for: smbNested, password: "secret")
    try expect(smbNestedPlan.standardInput?.contains("smb://nas.local/video/projects") == true, "SMB mount should normalize host and remote subpath")
    let quietSMBPlan = try MountPlanner().mountPlan(for: smbNested, password: "secret", suppressesUserInterface: true)
    try expect(quietSMBPlan.executable == "/sbin/mount_smbfs", "Quiet SMB mount should avoid AppleScript")
    try expect(quietSMBPlan.arguments.contains("nopassprompt,soft"), "Quiet SMB mount should suppress prompts and use a soft mount")
    try expect(quietSMBPlan.arguments.contains("//mei:secret@nas.local/video"), "Quiet SMB mount should mount the share only")
    try expect(MountPlanner().exposedPathTarget(for: smbNested)?.hasSuffix("/projects") == true, "Nested SMB mount should expose the subdirectory")
    try expect(MountPlanner().browsePath(for: smbNested).hasSuffix("/projects"), "Nested SMB Finder path should open the configured subdirectory")
    try expect(MountPlanner().browsePath(for: smb) == "/Volumes/Team", "Non-nested Finder path should open the visible mount point")

    let nfs = VolumeConfig(name: "Exports", protocolType: .nfs, server: "nas.local", remotePath: "/exports/team", username: nil, mountPoint: "/Volumes/Exports", checkIntervalSeconds: 60, isEnabled: true)
    let nfsPlan = try MountPlanner().mountPlan(for: nfs, password: nil)
    try expect(nfsPlan == CommandPlan(executable: "/sbin/mount_nfs", arguments: ["nas.local:/exports/team", "/Volumes/Exports"]), "NFS mount plan mismatch")

    let nfsURLServer = VolumeConfig(name: "NFS Media", protocolType: .nfs, server: "nfs://nas.local/ignored", remotePath: "exports/media", username: nil, mountPoint: "/Volumes/Media", checkIntervalSeconds: 60, isEnabled: true)
    let nfsURLServerPlan = try MountPlanner().mountPlan(for: nfsURLServer, password: nil)
    try expect(nfsURLServerPlan == CommandPlan(executable: "/sbin/mount_nfs", arguments: ["nas.local:/exports/media", "/Volumes/Media"]), "NFS should normalize server and remote subpath")

    let afp = VolumeConfig(name: "AFP Media", protocolType: .afp, server: "afp://nas.local/root", remotePath: "/media/projects", username: "mei", mountPoint: "/Volumes/AFPMedia", checkIntervalSeconds: 60, isEnabled: true)
    let afpPlan = try MountPlanner().mountPlan(for: afp, password: "secret")
    try expect(afpPlan.standardInput?.contains("afp://nas.local/media/projects") == true, "AFP should normalize host and remote subpath")

    let webdav = VolumeConfig(name: "DAV", protocolType: .webdav, server: "dav.example.com", remotePath: "remote.php/dav/files/mei", username: "mei", mountPoint: "/Volumes/DAV", checkIntervalSeconds: 60, isEnabled: true)
    let webdavPlan = try MountPlanner().mountPlan(for: webdav, password: "secret")
    try expect(webdavPlan.executable == "/usr/bin/osascript", "WebDAV mount should use the Finder-compatible AppleScript path")
    try expect(webdavPlan.standardInput?.contains("https://dav.example.com/remote.php/dav/files/mei") == true, "WebDAV mount script missing URL")

    let webdavRoot = VolumeConfig(name: "RootDAV", protocolType: .webdav, server: "https://dav.example.com/base", remotePath: "/", username: "mei", mountPoint: "/Volumes/RootDAV", checkIntervalSeconds: 60, isEnabled: true)
    let webdavRootPlan = try MountPlanner().mountPlan(for: webdavRoot, password: "secret")
    try expect(webdavRootPlan.standardInput?.contains("https://dav.example.com/base") == true, "WebDAV / should mount the server/base root without an extra path level")
    let quietWebDAVPlan = try MountPlanner().mountPlan(for: webdavRoot, password: "secret", suppressesUserInterface: true)
    try expect(quietWebDAVPlan.executable == "/usr/bin/osascript", "WebDAV quiet mount should use Finder-compatible AppleScript")
    try expect(quietWebDAVPlan.arguments == ["-"], "WebDAV AppleScript should be passed through stdin")
    try expect(quietWebDAVPlan.standardInput?.contains("mount volume \"https://dav.example.com/base\"") == true, "WebDAV quiet mount script missing URL")
    try expect(quietWebDAVPlan.standardInput?.contains("as user name \"mei\"") == true, "WebDAV quiet mount script missing username")
    try expect(quietWebDAVPlan.standardInput?.contains("with password \"secret\"") == true, "WebDAV quiet mount script missing password")
    try expect(quietWebDAVPlan.standardInput?.contains("mount_webdav") == false, "WebDAV quiet mount must not use mount_webdav/expect")
    let webdavRootNativeURL = try MountPlanner().remoteURLString(for: webdavRoot)
    try expect(webdavRootNativeURL == "https://dav.example.com/base", "WebDAV native mount URL should preserve the configured server root")
    let isolatedSettingsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: isolatedSettingsDirectory) }
    let defaultSettingsPlanner = MountPlanner(settingsStore: JSONAppSettingsStore(directory: isolatedSettingsDirectory))
    try expect(defaultSettingsPlanner.shouldOpenFinderAfterMount(for: webdavRoot), "WebDAV should open Finder after cleanup so the user lands in the real mounted folder")
    try expect(defaultSettingsPlanner.shouldOpenFinderAfterMount(for: smb), "Quiet SMB mount should still reveal the mounted folder")

    let unmountPlan = MountPlanner().unmountPlan(mountPoint: "/Volumes/Team")
    try expect(unmountPlan == CommandPlan(executable: "/usr/sbin/diskutil", arguments: ["unmount", "/Volumes/Team"]), "Unmount plan mismatch")
    let forceUnmountPlan = MountPlanner().forceUnmountPlan(mountPoint: "/Volumes/Team")
    try expect(forceUnmountPlan == CommandPlan(executable: "/sbin/umount", arguments: ["-f", "/Volumes/Team"]), "Force unmount plan mismatch")
    try expect(MountPlanner().unmountTarget(for: smbNested) == MountPlanner().effectiveMountPoint(for: smbNested), "Nested SMB unmount should target the backing mount point")
    let webdavMountOutput = "https://mei@dav.example.com/base on /Volumes/base (webdav, nodev, nosuid, mounted by mei)"
    try expect(MountPlanner().unmountTarget(for: webdavRoot, mountTable: SystemMountTable(mountOutput: webdavMountOutput)) == "/Volumes/base", "WebDAV unmount should target the real mounted path")
    try expect(MountPlanner().healthCheckPath(for: webdavRoot, mountTable: SystemMountTable(mountOutput: webdavMountOutput)) == "/Volumes/base", "WebDAV health check should use the real mounted path")
    try expect(MountPlanner().finderCleanupPaths(for: webdavRoot, resolvedBrowsePath: "/Volumes/base") == ["/Volumes/RootDAV", "/Volumes/base"], "Finder cleanup should include visible and resolved WebDAV paths once")
}

func testConnectivityPlanning() throws {
    let smb = VolumeConfig(name: "Team", protocolType: .smb, server: "smb://nas.local/team", remotePath: "team", username: "mei", mountPoint: "/Volumes/Team", checkIntervalSeconds: 60, isEnabled: true)
    let smbPlan = try ConnectivityTester().testPlan(for: smb, password: "secret")
    try expect(smbPlan == CommandPlan(executable: "/usr/bin/nc", arguments: ["-z", "-G", "5", "nas.local", "445"]), "SMB connectivity plan mismatch")

    let webdav = VolumeConfig(name: "DAV", protocolType: .webdav, server: "https://dav.example.com", remotePath: "remote.php/dav/files/mei", username: "mei", mountPoint: "/Volumes/DAV", checkIntervalSeconds: 60, isEnabled: true)
    let webdavPlan = try ConnectivityTester().testPlan(for: webdav, password: "secret")
    try expect(webdavPlan == CommandPlan(executable: "/usr/bin/curl", arguments: ["--user", "mei:secret", "--fail-with-body", "--silent", "--show-error", "--request", "PROPFIND", "--header", "Depth: 0", "--max-time", "10", "https://dav.example.com/remote.php/dav/files/mei"]), "WebDAV connectivity plan mismatch")

    let webdavBackslash = VolumeConfig(name: "DAVSlash", protocolType: .webdav, server: "https://dav.example.com/base", remotePath: "\\team\\video", username: nil, mountPoint: "/Volumes/DAVSlash", checkIntervalSeconds: 60, isEnabled: true)
    let webdavBackslashPlan = try ConnectivityTester().testPlan(for: webdavBackslash, password: nil)
    try expect(webdavBackslashPlan.arguments.last == "https://dav.example.com/base/team/video", "WebDAV connectivity should normalize backslashes")

    let unauthorized = CommandResult(exitCode: 22, stdout: "<html><title>401 Unauthorized</title></html>", stderr: "curl: (22) The requested URL returned error: 401")
    let unauthorizedCheck = ConnectivityTester().checkResult(for: webdav, result: unauthorized)
    try expect(!unauthorizedCheck.isReachable, "WebDAV 401 should not be treated as reachable")
    try expect(unauthorizedCheck.message?.contains("authentication failed") == true, "WebDAV 401 should produce an authentication message")
    try expect(unauthorizedCheck.messageKey == .errorConnectivityWebDAVUnauthorized, "WebDAV 401 should be keyed as errorConnectivityWebDAVUnauthorized")

    let forbidden = CommandResult(exitCode: 22, stdout: "<html><title>403 Forbidden</title></html>", stderr: "curl: (22) The requested URL returned error: 403")
    let forbiddenCheck = ConnectivityTester().checkResult(for: webdav, result: forbidden)
    try expect(!forbiddenCheck.isReachable, "WebDAV 403 should not be treated as reachable")
    try expect(forbiddenCheck.messageKey == .errorConnectivityWebDAVForbidden, "WebDAV 403 should be keyed as errorConnectivityWebDAVForbidden")

    let notFound = CommandResult(exitCode: 22, stdout: "<html><title>404 Not Found</title></html>", stderr: "curl: (22) The requested URL returned error: 404")
    let notFoundCheck = ConnectivityTester().checkResult(for: webdav, result: notFound)
    try expect(!notFoundCheck.isReachable, "WebDAV 404 should not be treated as reachable")
    try expect(notFoundCheck.messageKey == .errorConnectivityWebDAVNotFound, "WebDAV 404 should be keyed as errorConnectivityWebDAVNotFound")

    let timedOut = CommandResult(exitCode: 124, stdout: "", stderr: "")
    let unreachableCheck = ConnectivityTester().checkResult(for: webdav, result: timedOut)
    try expect(!unreachableCheck.isReachable, "WebDAV exit code 124 should not be treated as reachable")
    try expect(unreachableCheck.messageKey == .errorConnectivityUnreachable, "WebDAV exit code 124 should be keyed as errorConnectivityUnreachable")
    try expect(unreachableCheck.messageArgs == ["WebDAV"], "errorConnectivityUnreachable should carry the protocol display name as its arg")

    let nfs = VolumeConfig(name: "NFS", protocolType: .nfs, server: "nas.local", remotePath: "video", username: nil, mountPoint: "/Volumes/NFS", checkIntervalSeconds: 60, isEnabled: true)
    let nfsCheck = ConnectivityTester().checkResult(for: nfs, result: CommandResult(exitCode: 1, stdout: "", stderr: ""))
    try expect(!nfsCheck.isReachable, "NFS failed probe should not be treated as reachable")
    try expect(nfsCheck.message?.contains("port 2049") == true, "NFS failed probe should mention port 2049")
    try expect(nfsCheck.messageKey == .errorConnectivityNFSUnreachable, "NFS failed probe should be keyed as errorConnectivityNFSUnreachable")
}

/// Important 3 (final review): `AppViewModel.verifyConnectivity` must render a WebDAV
/// connectivity failure through `L10n.t(messageKey:...)`, not just the result's stored English
/// `message` — otherwise every WebDAV connectivity error thrown from `mount`/`testConnection`
/// stayed English no matter what language the user picked. `AppViewModel` itself isn't linked
/// into this shared-lib test binary, so this proves the underlying pieces the fixed call site
/// composes — `ConnectivityTester`'s keyed result plus `L10n.t(_:args:in:)` — actually render
/// non-English table text for a real failure (401 Unauthorized) once resolved in Japanese,
/// matching exactly what `connectivity.messageKey.map { L10n.t($0, args: ...) }` now does.
func testWebDAVUnauthorizedResultRendersInNonEnglishLanguage() throws {
    let webdav = VolumeConfig(name: "DAV", protocolType: .webdav, server: "https://dav.example.com", remotePath: "remote.php/dav/files/mei", username: "mei", mountPoint: "/Volumes/DAV", checkIntervalSeconds: 60, isEnabled: true)
    let unauthorized = CommandResult(exitCode: 22, stdout: "<html><title>401 Unauthorized</title></html>", stderr: "curl: (22) The requested URL returned error: 401")
    let checkResult = ConnectivityTester().checkResult(for: webdav, result: unauthorized)

    guard let messageKey = checkResult.messageKey else {
        throw ManualTestFailure.failed("401 result should carry a messageKey")
    }
    let renderedInJapanese = L10n.t(messageKey, args: checkResult.messageArgs, in: .ja)
    let renderedInEnglish = L10n.t(messageKey, args: checkResult.messageArgs, in: .en)
    try expect(renderedInJapanese != renderedInEnglish, "The Japanese rendering of a keyed WebDAV connectivity error must differ from the English rendering")
    try expect(renderedInJapanese != checkResult.message, "Rendering through the messageKey (not the stored English message) should be language-specific, not the always-English stored message")
}

func testMountExposureCreatesSubdirectoryLink() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }

    let config = VolumeConfig(
        id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
        name: "Tools",
        protocolType: .smb,
        server: "nas.example.test",
        remotePath: "share/tools",
        username: "user",
        mountPoint: directory.appendingPathComponent("Tools").path,
        checkIntervalSeconds: 60,
        isEnabled: true
    )
    let planner = MountPlanner()
    let exposure = MountExposure()

    try exposure.prepare(config: config, planner: planner)
    let target = planner.exposedPathTarget(for: config)!
    try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
    try exposure.expose(config: config, planner: planner)

    let destination = try FileManager.default.destinationOfSymbolicLink(atPath: config.mountPoint)
    try expect(destination == target, "Nested SMB exposure should point the visible mount entry at the configured subdirectory")
}

func testPathHealthProbe() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    try expect(PathHealthProbe(timeout: 1).isResponsive(path: directory.path), "Existing directory should be responsive")
    try expect(!PathHealthProbe(timeout: 1).isResponsive(path: directory.appendingPathComponent("missing").path), "Missing path should be unhealthy")
}

func testAutoVolumeLoggerRetentionAndSizeLimit() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let logger = AutoVolumeLogger(directory: directory, retentionInterval: 60, maxBytes: 160)
    let now = Date(timeIntervalSince1970: 1_000)

    logger.write(level: "INFO", message: "old line", date: now.addingTimeInterval(-120))
    logger.write(level: "INFO", message: "new line 1", date: now)
    logger.write(level: "INFO", message: "new line 2 with //user:secret@example.test/share", date: now.addingTimeInterval(1))
    try logger.prune(now: now.addingTimeInterval(2))

    let logText = try String(contentsOf: logger.logFileURL, encoding: .utf8)
    try expect(!logText.contains("old line"), "Logger should remove entries older than the retention window")
    try expect(logText.contains("new line"), "Logger should keep recent entries")
    try expect(!logText.contains("secret"), "Logger should redact URL passwords")
    guard let newestIndex = logText.range(of: "new line 2")?.lowerBound,
          let olderIndex = logText.range(of: "new line 1")?.lowerBound else {
        throw ManualTestFailure.failed("Logger output missing recent lines")
    }
    try expect(newestIndex < olderIndex, "Logger should show newest entries first")
    let size = (try FileManager.default.attributesOfItem(atPath: logger.logFileURL.path)[.size] as? NSNumber)?.intValue ?? 0
    try expect(size <= 160, "Logger should keep the file under the configured size limit")
}

/// Issue #3 ("first click on the volume list after a quiet spell freezes the UI for 5-30s"). The
/// Agent's `network-path-changed` loop inflated AutoVolume.log to ~88k lines; the app's first log
/// write after ≥60s of silence ("Opened volume list", on the main thread) ran the retention prune,
/// which parsed every line with ISO8601DateFormatter — ~0.3s per 6000 lines, i.e. ~5s here — and
/// the next clicks were instant only because the 60s throttle skipped the prune. A write must stay
/// cheap however long the log has grown.
func testAutoVolumeLoggerFirstWriteIntoHugeLogStaysFast() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let logger = AutoVolumeLogger(directory: directory)

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = .current
    let now = Date()
    let seededLineCount = 88_000
    var seeded = ""
    seeded.reserveCapacity(seededLineCount * 80)
    for index in 0..<seededLineCount {
        let date = now.addingTimeInterval(-Double(index) * 6)
        seeded += "\(formatter.string(from: date)) [INFO] Agent check mounted for video\n"
    }
    try FileManager.default.createDirectory(at: logger.logDirectoryURL, withIntermediateDirectories: true)
    try Data(seeded.utf8).write(to: logger.logFileURL)

    let start = Date()
    logger.write(level: "INFO", message: "Opened volume list", date: now)
    let elapsed = Date().timeIntervalSince(start)
    print("  first write into \(seededLineCount)-line log: \(elapsed)s")

    try expect(
        elapsed < 0.5,
        "First write() into an \(seededLineCount)-line log took \(elapsed)s — on the main thread this is the multi-second UI freeze from issue #3"
    )
}

/// Retention must drop exactly the expired suffix of a newest-first log — no more, no less — and do it
/// without parsing the in-window lines (that was the cost behind issue #3).
func testAutoVolumeLoggerPruneDropsOnlyExpiredSuffixOfHugeLog() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let logger = AutoVolumeLogger(directory: directory, retentionInterval: 3_600)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = .current
    let now = Date()
    // One line per second going back 80,000s: the newest 3,600 are inside the 1h window.
    var seeded = ""
    for index in 0..<80_000 {
        seeded += "\(formatter.string(from: now.addingTimeInterval(-Double(index)))) [INFO] line \(index)\n"
    }
    try FileManager.default.createDirectory(at: logger.logDirectoryURL, withIntermediateDirectories: true)
    try Data(seeded.utf8).write(to: logger.logFileURL)

    let start = Date()
    try logger.prune(now: now)
    let elapsed = Date().timeIntervalSince(start)

    let lines = try String(contentsOf: logger.logFileURL, encoding: .utf8).split(separator: "\n")
    try expect(lines.first?.hasSuffix("line 0") == true, "Newest line must survive pruning, got \(lines.first ?? "nil")")
    try expect(lines.last?.hasSuffix("line 3600") == true || lines.last?.hasSuffix("line 3599") == true,
               "Oldest kept line must sit at the retention boundary, got \(lines.last ?? "nil")")
    try expect(lines.count >= 3_600 && lines.count <= 3_601, "Expected ~3600 in-window lines, got \(lines.count)")
    try expect(elapsed < 1.0, "Pruning 76k expired lines took \(elapsed)s")
}

func testAutoVolumeLoggerPruneKeepsLinesItCannotDate() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let logger = AutoVolumeLogger(directory: directory, retentionInterval: 60)
    try FileManager.default.createDirectory(at: logger.logDirectoryURL, withIntermediateDirectories: true)
    try Data("not-a-timestamp stray line\n".utf8).write(to: logger.logFileURL)

    try logger.prune(now: Date())

    let text = try String(contentsOf: logger.logFileURL, encoding: .utf8)
    try expect(text.contains("stray line"), "Lines without a parseable timestamp must never be discarded")
}

/// Reproduces the reported "settings takes 3+ seconds to open, main-thread stalls get worse
/// the longer AutoVolume has been running without a restart" bug. `write()` used to re-parse
/// every existing line's ISO8601 timestamp and re-sort the whole file (twice, via a duplicated
/// `pruneLocked` call) on every single log line, so a single call's cost scaled with the total
/// number of lines ever logged rather than staying roughly constant. A fresh install (empty
/// log) never showed this; it only appeared after days of accumulated "Agent check"/stall
/// lines, which is exactly what this test seeds directly into the log file.
func testAutoVolumeLoggerWriteStaysFastAsLogGrowsOverDays() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let logger = AutoVolumeLogger(directory: directory)

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = .current
    let now = Date()
    // Newest-first, one line every 30s reaching back ~2 days — matches how AutoVolume.log
    // actually accumulates ("Agent check mounted" every few minutes, stall warnings, etc.)
    // without the app ever being restarted.
    let seededLineCount = 6000
    let seededLines = (0..<seededLineCount).map { index -> String in
        let date = now.addingTimeInterval(-Double(index) * 30)
        return "\(formatter.string(from: date)) [INFO] Agent check mounted for synology"
    }
    try FileManager.default.createDirectory(at: logger.logDirectoryURL, withIntermediateDirectories: true)
    try Data((seededLines.joined(separator: "\n") + "\n").utf8).write(to: logger.logFileURL)

    let start = Date()
    logger.write(level: "INFO", message: "Opened settings", date: now)
    let elapsed = Date().timeIntervalSince(start)

    // The first write() on a logger always runs one full prune — `lastAutoPruneDate`
    // starts nil — so this call legitimately pays a single O(n) pass over the whole
    // file. That is the price of the 60s throttle, not the regression being guarded
    // against; the regression was paying it on *every* line.
    //
    // The ceiling therefore only needs to bound one pass, and 0.3s sat directly on
    // the measured cost (0.28–0.32s on 6000 lines), so it flipped pass/fail at random
    // on a loaded machine. 1.0s keeps ~3x headroom for a busy disk while still failing
    // loudly on a real regression — re-parsing all of history per line costs orders of
    // magnitude more than this, so the guard is not weakened in any way that matters.
    try expect(
        elapsed < 1.0,
        "A single write() call took \(elapsed)s against a \(seededLineCount)-line log — cost must not scale with total accumulated log history"
    )

    // The throttle itself, checked by behaviour instead of by timing: a prune is cheap now, so a
    // first-vs-second wall-clock ratio no longer says anything. Plant an expired line at the tail
    // after the first write has pruned; a second write inside the 60s window must leave it alone
    // (no prune), and a write after the window must remove it.
    let expiredLine = "\(formatter.string(from: now.addingTimeInterval(-8 * 24 * 3_600))) [INFO] expired marker\n"
    let handle = try FileHandle(forWritingTo: logger.logFileURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(expiredLine.utf8))
    try handle.close()

    logger.write(level: "INFO", message: "Opened settings again", date: now.addingTimeInterval(1))
    var text = try String(contentsOf: logger.logFileURL, encoding: .utf8)
    try expect(text.contains("expired marker"), "A second write inside the 60s window must not prune — the auto-prune throttle is not holding")

    logger.write(level: "INFO", message: "Opened settings much later", date: now.addingTimeInterval(61))
    text = try String(contentsOf: logger.logFileURL, encoding: .utf8)
    try expect(!text.contains("expired marker"), "A write after the 60s window must run the retention prune and drop the expired line")
}

func testServerHostSetDedupesByHostnameAndSkipsDisabled() throws {
    let enabledA = VolumeConfig(name: "A", protocolType: .webdav, server: "https://nas.example.com:5006", remotePath: "a", username: nil, mountPoint: "/tmp/a-\(UUID().uuidString)", checkIntervalSeconds: 300, isEnabled: true)
    let enabledB = VolumeConfig(name: "B", protocolType: .webdav, server: "https://nas.example.com:5006", remotePath: "b", username: nil, mountPoint: "/tmp/b-\(UUID().uuidString)", checkIntervalSeconds: 300, isEnabled: true)
    let disabled = VolumeConfig(name: "C", protocolType: .smb, server: "other.example.com", remotePath: "c", username: nil, mountPoint: "/tmp/c-\(UUID().uuidString)", checkIntervalSeconds: 300, isEnabled: false)
    let smb = VolumeConfig(name: "D", protocolType: .smb, server: "smb.example.com", remotePath: "d", username: nil, mountPoint: "/tmp/d-\(UUID().uuidString)", checkIntervalSeconds: 300, isEnabled: true)

    let hosts = ServerHostSet.hosts(for: [enabledA, enabledB, disabled, smb])

    try expect(hosts == Set(["nas.example.com", "smb.example.com"]), "expected deduped, enabled-only hostnames, got \(hosts)")
}

func testManagedMountPointsUsesBackingDirectoryForSMBWithSubpath() throws {
    let smbWithSubpath = VolumeConfig(name: "Share", protocolType: .smb, server: "nas.local", remotePath: "share/subdir", username: nil, mountPoint: "/tmp/mount-point-\(UUID().uuidString)", checkIntervalSeconds: 300, isEnabled: true)
    let webdav = VolumeConfig(name: "WebDAV", protocolType: .webdav, server: "nas.local", remotePath: "docs", username: nil, mountPoint: "/tmp/webdav-\(UUID().uuidString)", checkIntervalSeconds: 300, isEnabled: true)
    let disabled = VolumeConfig(name: "Off", protocolType: .webdav, server: "nas.local", remotePath: "off", username: nil, mountPoint: "/tmp/off-\(UUID().uuidString)", checkIntervalSeconds: 300, isEnabled: false)

    let planner = MountPlanner()
    let paths = ManagedMountPoints.paths(for: [smbWithSubpath, webdav, disabled], planner: planner)

    try expect(!paths.contains(smbWithSubpath.mountPoint), "SMB-with-subpath's symlink path must not be treated as the real mount point")
    try expect(paths.contains(planner.effectiveMountPoint(for: smbWithSubpath)), "must use the real backing directory for SMB-with-subpath")
    try expect(paths.contains(webdav.mountPoint), "with no live mount table entry, webdav falls back to config.mountPoint (no symlink indirection like SMB-with-subpath has)")
    try expect(paths.count == 2, "disabled volume must be excluded, got \(paths)")
}

func testManagedMountPointsUsesLiveMountTableForWebDAV() throws {
    let webdav = VolumeConfig(name: "home", protocolType: .webdav, server: "https://nas.example.com:5006", remotePath: "home", username: nil, mountPoint: "/Users/xiaoan/Volumes/home", checkIntervalSeconds: 300, isEnabled: true)
    let fakeMountOutput = "https://nas.example.com:5006/home/ on /Volumes/home (webdav, nodev, noexec, nosuid, mounted by xiaoan)\n"
    let mountTable = SystemMountTable(mountOutput: fakeMountOutput)
    let planner = MountPlanner()

    let paths = ManagedMountPoints.paths(for: [webdav], planner: planner, mountTable: mountTable)

    try expect(paths.contains("/Volumes/home"), "should resolve to the live osascript-mounted path from the system mount table, not config.mountPoint")
    try expect(!paths.contains(webdav.mountPoint), "config.mountPoint (\(webdav.mountPoint)) is not where WebDAV actually gets mounted — this is exactly the bug the final review caught")
}

func testAgentEngineDecisions() throws {
    let testMountRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: testMountRoot) }
    let disabled = VolumeConfig(name: "Off", protocolType: .smb, server: "nas.local", remotePath: "off", username: nil, mountPoint: testMountRoot.appendingPathComponent("Off").path, checkIntervalSeconds: 60, isEnabled: false)
    let disabledEngine = AgentEngine(mountState: FakeMountStateProvider(isMounted: false), credentialStore: InMemoryCredentialStore(), commandRunner: RecordingCommandRunner(), mountPlanner: MountPlanner())
    let disabledStatus = try disabledEngine.check(disabled)
    try expect(disabledStatus == .unmounted, "Disabled volume should be skipped")

    let mounted = VolumeConfig(name: "Team", protocolType: .smb, server: "nas.local", remotePath: "team", username: nil, mountPoint: testMountRoot.appendingPathComponent("Mounted").path, checkIntervalSeconds: 60, isEnabled: true)
    let mountedRunner = RecordingCommandRunner()
    let mountedEngine = AgentEngine(mountState: FakeMountStateProvider(isMounted: true), credentialStore: InMemoryCredentialStore(), commandRunner: mountedRunner, mountPlanner: MountPlanner())
    let mountedStatus = try mountedEngine.check(mounted)
    try expect(mountedStatus == .mounted, "Mounted volume should stay mounted")
    try expect(mountedRunner.plans.isEmpty, "Mounted volume should not run a command")

    let id = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    let unmounted = VolumeConfig(id: id, name: "Team", protocolType: .smb, server: "nas.local", remotePath: "team", username: "mei", mountPoint: testMountRoot.appendingPathComponent("Unmounted").path, checkIntervalSeconds: 60, isEnabled: true)
    let credentials = InMemoryCredentialStore()
    try credentials.savePassword("secret", for: id)
    let unmountedRunner = RecordingCommandRunner(result: CommandResult(exitCode: 0, stdout: "", stderr: ""))
    let unmountedEngine = AgentEngine(mountState: FakeMountStateProvider(isMounted: false), credentialStore: credentials, commandRunner: unmountedRunner, mountPlanner: MountPlanner())
    let unmountedStatus = try unmountedEngine.check(unmounted)
    try expect(unmountedStatus == .mounted, "Unmounted volume should mount successfully")
    try expect(unmountedRunner.plans.first?.executable == "/sbin/mount_smbfs", "Agent should use quiet SMB mount")

    let occupiedRunner = SequenceCommandRunner(results: [
        CommandResult(exitCode: 1, stdout: "", stderr: "mount_smbfs: File exists"),
        CommandResult(exitCode: 0, stdout: "", stderr: ""),
        CommandResult(exitCode: 0, stdout: "", stderr: ""),
        CommandResult(exitCode: 0, stdout: "", stderr: "")
    ])
    let occupiedEngine = AgentEngine(mountState: FakeMountStateProvider(isMounted: false), credentialStore: credentials, commandRunner: occupiedRunner, mountPlanner: MountPlanner())
    let occupiedStatus = try occupiedEngine.check(unmounted)
    try expect(occupiedStatus == .mounted, "Occupied stale mount point should be unmounted and retried")
    try expect(occupiedRunner.plans.map(\.executable) == ["/sbin/mount_smbfs", "/usr/sbin/diskutil", "/sbin/umount", "/sbin/mount_smbfs"], "Occupied stale mount point recovery command order mismatch")

    let reconnectRunner = SequenceCommandRunner(results: [
        CommandResult(exitCode: 0, stdout: "", stderr: ""),
        CommandResult(exitCode: 0, stdout: "", stderr: ""),
        CommandResult(exitCode: 0, stdout: "", stderr: "")
    ])
    let reconnectEngine = AgentEngine(mountState: FakeMountStateProvider(isMounted: true), credentialStore: credentials, commandRunner: reconnectRunner, mountPlanner: MountPlanner())
    let reconnectStatus = try reconnectEngine.reconnect(unmounted)
    try expect(reconnectStatus == .mounted, "Reconnect should remount after a network outage")
    try expect(reconnectRunner.plans.map(\.executable) == ["/usr/sbin/diskutil", "/sbin/umount", "/sbin/mount_smbfs"], "Reconnect command order mismatch")

}

// MARK: - Stale mounts, agent log spam (issues #1, #2, #3)

/// `FileManager` whose `createDirectory` fails the first `failures` times, the way it does when a dead
/// mount still occupies the mount point ("The file “video” couldn’t be saved in the folder “Volumes”").
final class FlakyCreateDirectoryFileManager: FileManager {
    var remainingFailures: Int
    init(failures: Int) {
        self.remainingFailures = failures
        super.init()
    }
    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]? = nil) throws {
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}

/// Issue #2: after a network blip the SMB mount went stale, the mount point could no longer be prepared,
/// and the agent logged the same createDirectory error every cycle for an hour — until a reboot.
func testAgentEngineClearsDeadMountThatBlocksMountPointPreparation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let config = VolumeConfig(id: id, name: "video", protocolType: .smb, server: "nas.local", remotePath: "video", username: "mei", mountPoint: root.appendingPathComponent("video").path, checkIntervalSeconds: 300, isEnabled: true)
    let credentials = InMemoryCredentialStore()
    try credentials.savePassword("secret", for: id)
    let runner = RecordingCommandRunner()
    let engine = AgentEngine(
        mountState: FakeMountStateProvider(isMounted: false),
        credentialStore: credentials,
        commandRunner: runner,
        mountPlanner: MountPlanner(),
        mountExposure: MountExposure(fileManager: FlakyCreateDirectoryFileManager(failures: 1)),
        mountTable: SystemMountTable(mountOutput: "//mei@nas.local/video on \(config.mountPoint) (smbfs, nodev, nosuid, mounted by mei)\n")
    )

    let status = try engine.check(config)

    try expect(status == .mounted, "A blocked mount point should be cleared and the volume mounted, got \(status)")
    try expect(runner.plans.map(\.executable) == ["/usr/sbin/diskutil", "/sbin/umount", "/sbin/mount_smbfs"],
               "Expected unmount, force unmount, then mount; got \(runner.plans.map(\.executable))")
}

func testAgentEngineStillReportsAMountPointThatCannotBePreparedEvenAfterUnmount() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let config = VolumeConfig(id: id, name: "video", protocolType: .smb, server: "nas.local", remotePath: "video", username: "mei", mountPoint: root.appendingPathComponent("video").path, checkIntervalSeconds: 300, isEnabled: true)
    let credentials = InMemoryCredentialStore()
    try credentials.savePassword("secret", for: id)
    let runner = RecordingCommandRunner()
    let engine = AgentEngine(
        mountState: FakeMountStateProvider(isMounted: false),
        credentialStore: credentials,
        commandRunner: runner,
        mountPlanner: MountPlanner(),
        mountExposure: MountExposure(fileManager: FlakyCreateDirectoryFileManager(failures: 2)),
        mountTable: SystemMountTable(mountOutput: "//mei@nas.local/video on \(config.mountPoint) (smbfs, nodev, nosuid, mounted by mei)\n")
    )

    var thrown = false
    do { _ = try engine.check(config) } catch { thrown = true }

    try expect(thrown, "If the mount point is still unusable after clearing it, the error must surface instead of being swallowed")
    try expect(!runner.plans.map(\.executable).contains("/sbin/mount_smbfs"), "No mount should be attempted onto an unusable mount point")
}

/// Issue #2/#3: NWPathMonitor reported ~29,000 "changes" a week on a machine whose network never changed
/// (AWDL / low-latency-WLAN interfaces flap constantly); each one ran a full check and wrote log lines.
func testNetworkPathFilterIgnoresPeerToPeerInterfaceFlapping() throws {
    var filter = NetworkPathChangeFilter()
    let wifi = NetworkPathSignature(status: "satisfied", interfaces: [.init(name: "en0", type: "wifi")])
    let wifiWithAwdl = NetworkPathSignature(status: "satisfied", interfaces: [.init(name: "en0", type: "wifi"), .init(name: "awdl0", type: "other")])
    let wifiWithLlw = NetworkPathSignature(status: "satisfied", interfaces: [.init(name: "llw0", type: "other"), .init(name: "en0", type: "wifi")])

    try expect(filter.shouldTrigger(for: wifi), "The first path update must trigger a check")
    try expect(!filter.shouldTrigger(for: wifiWithAwdl), "AWDL appearing is not a network change")
    try expect(!filter.shouldTrigger(for: wifi), "AWDL disappearing is not a network change")
    try expect(!filter.shouldTrigger(for: wifiWithLlw), "llw0 flapping is not a network change")
    try expect(!filter.shouldTrigger(for: wifi), "an identical update is not a change")
}

func testNetworkPathFilterTriggersOnRealChanges() throws {
    var filter = NetworkPathChangeFilter()
    let wifi = NetworkPathSignature(status: "satisfied", interfaces: [.init(name: "en0", type: "wifi")])
    let wifiAndVPN = NetworkPathSignature(status: "satisfied", interfaces: [.init(name: "en0", type: "wifi"), .init(name: "utun4", type: "other")])
    let offline = NetworkPathSignature(status: "unsatisfied", interfaces: [])
    let ethernet = NetworkPathSignature(status: "satisfied", interfaces: [.init(name: "en5", type: "wiredEthernet")])

    _ = filter.shouldTrigger(for: wifi)
    try expect(filter.shouldTrigger(for: wifiAndVPN), "A VPN coming up can make the NAS reachable")
    try expect(filter.shouldTrigger(for: wifi), "VPN going down")
    try expect(filter.shouldTrigger(for: offline), "Going offline")
    try expect(filter.shouldTrigger(for: ethernet), "Coming back on a different interface")
}

func testNetworkPathFilterTreatsInterfaceOrderAsIrrelevant() throws {
    var filter = NetworkPathChangeFilter()
    let a = NetworkPathSignature(status: "satisfied", interfaces: [.init(name: "en0", type: "wifi"), .init(name: "en5", type: "wiredEthernet")])
    let b = NetworkPathSignature(status: "satisfied", interfaces: [.init(name: "en5", type: "wiredEthernet"), .init(name: "en0", type: "wifi")])
    _ = filter.shouldTrigger(for: a)
    try expect(!filter.shouldTrigger(for: b), "The same interfaces in a different order are the same network")
}

/// "Agent check mounted for X" used to be written on every check — 29,000+ lines a week, 6.5MB of log
/// that buried everything useful. Only a change of state is worth a line.
func testStatusTransitionTrackerLogsOnlyChanges() throws {
    var tracker = StatusTransitionTracker()
    let a = UUID()
    let b = UUID()

    try expect(tracker.shouldLog(volumeID: a, state: "mounted"), "first observation is news")
    try expect(!tracker.shouldLog(volumeID: a, state: "mounted"), "unchanged is not")
    try expect(!tracker.shouldLog(volumeID: a, state: "mounted"), "still unchanged")
    try expect(tracker.shouldLog(volumeID: b, state: "mounted"), "volumes are tracked independently")
    try expect(tracker.shouldLog(volumeID: a, state: "failed: boom"), "a failure is news")
    try expect(!tracker.shouldLog(volumeID: a, state: "failed: boom"), "the same failure repeating is not")
    try expect(tracker.shouldLog(volumeID: a, state: "failed: different"), "a different failure is")
    try expect(tracker.shouldLog(volumeID: a, state: "mounted"), "recovery is news")
}

/// Code review finding: the recovery must only unmount what is mounted at the path that could not be
/// prepared. A healthy mount of the same share somewhere else (Finder's /Volumes/foo) belongs to the
/// user and must never be force-ejected because an unrelated createDirectory error happened.
func testAgentEngineDoesNotUnmountAnythingWhenNothingIsMountedAtTheFailingPath() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let config = VolumeConfig(id: id, name: "video", protocolType: .nfs, server: "192.168.3.106", remotePath: "video", username: nil, mountPoint: root.appendingPathComponent("video").path, checkIntervalSeconds: 300, isEnabled: true)
    let credentials = InMemoryCredentialStore()
    let runner = RecordingCommandRunner()
    let engine = AgentEngine(
        mountState: FakeMountStateProvider(isMounted: false),
        credentialStore: credentials,
        commandRunner: runner,
        mountPlanner: MountPlanner(),
        mountExposure: MountExposure(fileManager: FlakyCreateDirectoryFileManager(failures: 1)),
        mountTable: SystemMountTable(mountOutput: "192.168.3.106:/video on /Volumes/foo (nfs, nodev, nosuid, mounted by andy)\n")
    )

    var thrown = false
    do { _ = try engine.check(config) } catch { thrown = true }

    try expect(thrown, "The preparation error must surface")
    try expect(runner.plans.isEmpty, "Nothing is mounted at the failing path, so nothing may be unmounted — got \(runner.plans.map(\.executable))")
}

/// Code review finding: switching Wi-Fi network / subnet on the same interface is a real change.
func testNetworkPathFilterTriggersWhenTheGatewayChangesOnTheSameInterface() throws {
    var filter = NetworkPathChangeFilter()
    let home = NetworkPathSignature(status: "satisfied", interfaces: [.init(name: "en0", type: "wifi")], gateways: ["192.168.3.1"])
    let office = NetworkPathSignature(status: "satisfied", interfaces: [.init(name: "en0", type: "wifi")], gateways: ["10.0.0.1"])
    _ = filter.shouldTrigger(for: home)
    try expect(filter.shouldTrigger(for: office), "A different gateway on the same interface is a different network")
    try expect(!filter.shouldTrigger(for: office), "but repeating it is not news")
}

/// Code review finding: the tracker must also learn about states that are not logged, otherwise a volume
/// that goes mounted → unmounted → mounted never logs the second "mounted".
func testStatusTransitionTrackerNoticesRecoveryAfterUnloggedStates() throws {
    var tracker = StatusTransitionTracker()
    let id = UUID()
    try expect(tracker.shouldLog(volumeID: id, state: "mounted"), "first mount")
    _ = tracker.shouldLog(volumeID: id, state: "unmounted")
    try expect(tracker.shouldLog(volumeID: id, state: "mounted"), "mounting again after an unmount is news")
}

/// Code review finding: when `mount` itself fails, the table must say so once instead of re-running it.
func testSystemMountTableReportsUnreadableTableInsteadOfEmpty() throws {
    let unreadable = SystemMountTable(unavailable: true)
    let config = VolumeConfig(name: "v", protocolType: .smb, server: "nas", remotePath: "share", username: nil, mountPoint: "/Users/x/Volumes/v", checkIntervalSeconds: 300, isEnabled: true)
    try expect(unreadable.entries(matching: config) == nil, "An unreadable mount table must be reported as nil, not as 'nothing mounted'")
    try expect(unreadable.snapshot().entries(matching: config) == nil, "snapshot() of an unreadable table stays unreadable")
}

/// Code review finding: IPv6 literals and bracketed hosts.
func testMountStateHandlesIPv6AndBracketedHosts() throws {
    let nfsOutput = "[fe80::1]:/video on /Users/x/Volumes/video (nfs, nodev, nosuid, mounted by x)\n"
    let nfs = volume(.nfs, server: "[fe80::1]", remote: "video", at: "/Users/x/Volumes/video")
    try expect(mountedState(nfsOutput).isMounted(config: nfs), "A bracketed IPv6 NFS source must be parsed as host fe80::1, not 'fe80'")
    let smbOutput = "//u@[fe80::1]/share on /Users/x/Volumes/share (smbfs, nodev, nosuid, mounted by x)\n"
    let smb = volume(.smb, server: "[fe80::1]", remote: "share", at: "/Users/x/Volumes/share")
    try expect(mountedState(smbOutput).isMounted(config: smb), "A bracketed IPv6 SMB source must match")
}

// MARK: - NFS configuration (user report "nfs及 Jellyfin 问题")

/// Real `showmount -e` output of the Synology NAS in the report: the shares are exported by their FULL
/// path (`/volume1/video`), not by share name.
private let synologyShowmount = """
Exports list on 192.168.3.106:
/volume1/video                      192.168.3.110 192.168.3.5
/volume1/immich-media               192.168.3.0/24
"""

/// The failing stderr from the user's diagnostics: the app sent `/video`, the NAS only exports `/volume1/video`.
private let issueNFSDenied = "mount_nfs: can't mount /video from 192.168.3.106 onto /Users/andy/Volumes/video: Permission denied"

func testNFSQuietMountPlanUsesTheUsersProvenOptions() throws {
    let nfs = VolumeConfig(name: "video", protocolType: .nfs, server: "192.168.3.106", remotePath: "/volume1/video", username: nil, mountPoint: "/Users/andy/Volumes/video", checkIntervalSeconds: 300, isEnabled: true)
    let plan = try MountPlanner().mountPlan(for: nfs, password: nil, suppressesUserInterface: true)
    try expect(plan == CommandPlan(
        executable: "/sbin/mount_nfs",
        arguments: ["-o", "soft,nolocks,noowners,noatime,rsize=1048576,wsize=1048576", "192.168.3.106:/volume1/video", "/Users/andy/Volumes/video"]
    ), "NFS quiet mount plan should carry the options that mounted this NAS by hand, minus resvport (root only) and without pinning the NFS version, so negotiation is unchanged; got \(plan.arguments)")
}

func testNFSExportParsingReadsTheFirstColumnOfShowmount() throws {
    let exports = NFSExportResolver.parseExports(showmountOutput: synologyShowmount)
    try expect(exports == ["/volume1/video", "/volume1/immich-media"], "Expected the two exported paths, got \(exports)")
    try expect(NFSExportResolver.parseExports(showmountOutput: "Exports list on nas:\n").isEmpty, "A server with no exports has an empty list")
    try expect(NFSExportResolver.parseExports(showmountOutput: "").isEmpty, "Empty output parses to nothing")
}

func testNFSResolverFindsTheFullExportPathFromAShareName() throws {
    let exports = ["/volume1/video", "/volume1/immich-media"]
    // What the user had: the SMB share name, which the planner turns into "/video".
    try expect(NFSExportResolver.resolve(requested: "video", exports: exports) == .matched(path: "/volume1/video"), "'video' is the share /volume1/video")
    try expect(NFSExportResolver.resolve(requested: "/video", exports: exports) == .matched(path: "/volume1/video"), "'/video' is the share /volume1/video")
    try expect(NFSExportResolver.resolve(requested: "video/精选电视剧", exports: exports) == .matched(path: "/volume1/video/精选电视剧"), "a subfolder keeps its tail")
    try expect(NFSExportResolver.resolve(requested: "VIDEO", exports: exports) == .matched(path: "/volume1/video"), "matching a name ignores case but returns the server's spelling")
}

func testNFSResolverLeavesCorrectPathsAlone() throws {
    let exports = ["/volume1/video", "/volume1/immich-media"]
    try expect(NFSExportResolver.resolve(requested: "/volume1/video", exports: exports) == .exported(path: "/volume1/video"), "an exported path is used as is")
    try expect(NFSExportResolver.resolve(requested: "/volume1/video/精选电视剧", exports: exports) == .exported(path: "/volume1/video/精选电视剧"), "a folder inside an export is mountable as is")
    try expect(NFSExportResolver.resolve(requested: "/volume1/video/", exports: exports) == .exported(path: "/volume1/video"), "trailing slash is ignored")
}

func testNFSResolverListsExportsWhenNothingMatchesOrItIsAmbiguous() throws {
    let exports = ["/volume1/video", "/volume1/immich-media"]
    try expect(NFSExportResolver.resolve(requested: "music", exports: exports) == .notExported(available: exports), "unknown share lists what the server exports")
    try expect(NFSExportResolver.resolve(requested: "immich", exports: exports) == .notExported(available: exports), "'immich' is not 'immich-media' — no fuzzy guessing")
    try expect(NFSExportResolver.resolve(requested: "video", exports: ["/volume1/video", "/volume2/video"]) == .ambiguous(candidates: ["/volume1/video", "/volume2/video"]), "two shares named video must not be guessed")
    try expect(NFSExportResolver.resolve(requested: "video", exports: []) == .notExported(available: []), "a server exporting nothing")
}

/// The agent mounts unattended, so a misleading failure ("Permission denied") must say what to check.
func testNFSDiagnosisNamesTheExportsWhenThePathIsNotExported() throws {
    let exports = ["/volume1/video", "/volume1/immich-media"]
    let d = NFSMountDiagnostics.diagnose(stderr: issueNFSDenied, requestedPath: "/video", exports: ["/volume1/music"])
    try expect(d?.key == .errorNFSExportNotFound, "a denied path that is not exported is 'export not found', got \(String(describing: d?.key))")
    try expect(d?.args == ["/volume1/music"], "the message lists what the server exports, got \(String(describing: d?.args))")
    let sameNameDifferentPath = NFSMountDiagnostics.diagnose(stderr: issueNFSDenied, requestedPath: "/video", exports: exports)
    try expect(sameNameDifferentPath?.key == .errorNFSExportNotFound, "/video is not exported even though /volume1/video is")
}

func testNFSDiagnosisBlamesTheServerRulesWhenThePathIsExported() throws {
    let denied = "mount_nfs: can't mount /volume1/video from 192.168.3.106 onto /Users/andy/Volumes/video: Permission denied"
    let withList = NFSMountDiagnostics.diagnose(stderr: denied, requestedPath: "/volume1/video", exports: ["/volume1/video"])
    try expect(withList?.key == .errorNFSAccessDenied, "an exported path that is still denied is a client-rule / port problem")
    let noList = NFSMountDiagnostics.diagnose(stderr: issueNFSDenied, requestedPath: "/video", exports: nil)
    try expect(noList?.key == .errorNFSAccessDenied, "without an export list the message covers every cause, got \(String(describing: noList?.key))")
}

func testNFSDiagnosisSeparatesLocalPermissionFromServerPermission() throws {
    // /Volumes is root-owned, and resvport needs root: that is macOS refusing, not the NAS.
    let local = "mount_nfs: can't mount /volume1/video from 192.168.3.106 onto /Volumes/video: Operation not permitted"
    try expect(NFSMountDiagnostics.diagnose(stderr: local, requestedPath: "/volume1/video", exports: ["/volume1/video"])?.key == .errorNFSNotPermitted,
               "'Operation not permitted' is local")
    try expect(NFSMountDiagnostics.diagnose(stderr: "mount_nfs: can't mount /x from nas: RPC: Program not registered", requestedPath: "/x", exports: nil) == nil,
               "unrelated errors keep their raw text")
    try expect(NFSMountDiagnostics.diagnose(stderr: "", requestedPath: "/x", exports: nil) == nil, "no stderr, no diagnosis")
}

func testNFSDiagnosisMessagesExistInEveryLanguage() throws {
    for language in [ResolvedLanguage.zh, .en, .ko, .ja, .ru] {
        let table = L10n.table(language)
        for key in [L10nKey.errorNFSExportNotFound, .errorNFSAccessDenied, .errorNFSNotPermitted, .editorRemotePathHelpNFS, .statusNFSPathCorrected] {
            try expect(!(table[key.rawValue] ?? "").isEmpty, "\(language.rawValue) missing \(key.rawValue)")
        }
    }
    try expect(L10n.t(.errorNFSAccessDenied, args: [], in: .zh).contains("/volume1"), "the Chinese hint names the Synology export form")
    try expect(L10n.t(.errorNFSExportNotFound, args: ["/volume1/video"], in: .en).contains("/volume1/video"), "the export list is interpolated")
}

/// `showmount -e` hung for over a minute against an unreachable host; nothing may wait on it for that long.
func testTimedCommandKillsAProcessThatOutlivesItsTimeout() throws {
    let start = Date()
    let result = TimedCommand.run(executable: "/bin/sleep", arguments: ["30"], timeout: 0.4)
    let elapsed = Date().timeIntervalSince(start)
    try expect(result == nil, "a timed-out command reports nil")
    try expect(elapsed < 3, "the process must be killed at the timeout, took \(elapsed)s")
    let ok = TimedCommand.run(executable: "/bin/echo", arguments: ["hi"], timeout: 5)
    try expect(ok?.exitCode == 0 && ok?.stdout == "hi\n", "a fast command returns its output, got \(String(describing: ok))")
}

/// The agent mounts with nobody watching, so the alert it records is all the user ever sees. For the real
/// failure in the report the raw "Permission denied" gave no hint that the path was the problem.
func testAgentEngineExplainsAnNFSPermissionDenied() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let config = VolumeConfig(id: id, name: "video", protocolType: .nfs, server: "192.168.3.106", remotePath: "video", username: nil, mountPoint: root.appendingPathComponent("video").path, checkIntervalSeconds: 300, isEnabled: true)
    let runner = SequenceCommandRunner(results: [CommandResult(exitCode: 13, stdout: "", stderr: issueNFSDenied)])
    let engine = AgentEngine(mountState: FakeMountStateProvider(isMounted: false), credentialStore: InMemoryCredentialStore(), commandRunner: runner, mountPlanner: MountPlanner())

    let status = try engine.check(config)

    guard case .failed(let message, let key, _) = status else {
        throw ManualTestFailure.failed("Expected a failed status, got \(status)")
    }
    try expect(key == L10nKey.errorNFSAccessDenied.rawValue, "The alert should carry the NFS access-denied key, got \(String(describing: key))")
    try expect(message.contains("/volume1/"), "The English message should tell the user what path form NFS needs, got: \(message)")
    try expect(!message.contains("mount_nfs:"), "The raw command output should be replaced by the explanation")
}

func testAgentEngineKeepsRawTextForUnrelatedNFSErrors() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = VolumeConfig(id: UUID(), name: "video", protocolType: .nfs, server: "192.168.3.106", remotePath: "/volume1/video", username: nil, mountPoint: root.appendingPathComponent("video").path, checkIntervalSeconds: 300, isEnabled: true)
    let runner = SequenceCommandRunner(results: [CommandResult(exitCode: 1, stdout: "", stderr: "mount_nfs: can't mount /volume1/video from 192.168.3.106: RPC: Program not registered")])
    let engine = AgentEngine(mountState: FakeMountStateProvider(isMounted: false), credentialStore: InMemoryCredentialStore(), commandRunner: runner, mountPlanner: MountPlanner())

    let status = try engine.check(config)

    guard case .failed(let message, let key, _) = status else { throw ManualTestFailure.failed("Expected failed, got \(status)") }
    try expect(key == nil && message.contains("Program not registered"), "An error we cannot explain keeps its raw text, got \(message)")
}

/// Code review: "Operation not permitted" does not always mean "wrong mount point location". When the mount
/// point is already inside the user's own folder, telling them to move it there is wrong advice.
func testNFSDiagnosisOnlyBlamesTheMountPointWhenItIsOutsideTheHomeFolder() throws {
    let inHome = "mount_nfs: can't mount /volume1/video from 192.168.3.106 onto /Users/andy/Volumes/video: Operation not permitted"
    try expect(NFSMountDiagnostics.diagnose(stderr: inHome, requestedPath: "/volume1/video", exports: nil, homeDirectory: "/Users/andy") == nil,
               "a mount point inside the home folder is not the problem; keep the raw error")
    let system = "mount_nfs: can't mount /volume1/video from 192.168.3.106 onto /Volumes/video: Operation not permitted"
    try expect(NFSMountDiagnostics.diagnose(stderr: system, requestedPath: "/volume1/video", exports: nil, homeDirectory: "/Users/andy")?.key == .errorNFSNotPermitted,
               "/Volumes is system-owned: say so")
    try expect(NFSMountDiagnostics.diagnose(stderr: "mount_nfs: Operation not permitted", requestedPath: "/x", exports: nil, homeDirectory: "/Users/andy")?.key == .errorNFSNotPermitted,
               "with no mount point in the message, assume the common cause")
}

/// Code review: the export lookup blocks, so on the main thread it must refuse instead of freezing the UI.
func testShowmountListerRefusesToBlockTheMainThread() throws {
    try expect(Thread.isMainThread, "this harness runs on the main thread")
    let start = Date()
    let exports = ShowmountExportLister(timeout: 4).exports(host: "192.0.2.1")
    try expect(exports == nil, "no lookup on the main thread")
    try expect(Date().timeIntervalSince(start) < 0.5, "and it must return immediately")
}

/// Code review: a command that writes more than a pipe buffer (64 KB) must not be mistaken for a hang.
func testTimedCommandHandlesLargeOutput() throws {
    let result = TimedCommand.run(executable: "/bin/sh", arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' a"], timeout: 5)
    try expect(result?.exitCode == 0, "the command finished, got \(String(describing: result))")
    try expect(result?.stdout.count == 300_000, "all output is captured, got \(result?.stdout.count ?? -1) bytes")
}

// MARK: - Mount identity (issues #1, #3)

/// Mount table captured in the issue #3 diagnostics (18:57). The configured NFS volume "video" uses
/// mount point /Users/andy/Volumes/video — which is occupied by an *SMB* mount of the same share.
private let issue3MountOutput = """
//anweining@192.168.3.100/video on /Volumes/video (smbfs, nodev, nosuid, mounted by andy)
//anweining@192.168.3.106/video on /Users/andy/Volumes/video (smbfs, nodev, nosuid, mounted by andy)
//anweining@192.168.3.106/home on /Users/andy/Volumes/home (smbfs, nodev, nosuid, mounted by andy)
//anweining@192.168.3.100/homes on /Volumes/homes (smbfs, nodev, nosuid, mounted by andy)
//anweining@192.168.3.106/homes on /Volumes/homes-1 (smbfs, nodev, nosuid, mounted by andy)
"""

private func mountedState(_ output: String) -> FileSystemMountStateProvider {
    FileSystemMountStateProvider(mountTable: SystemMountTable(mountOutput: output), validatesResponsiveness: false)
}

private func volume(_ protocolType: VolumeProtocol, server: String, remote: String, at mountPoint: String) -> VolumeConfig {
    VolumeConfig(name: "v", protocolType: protocolType, server: server, remotePath: remote, username: "u", mountPoint: mountPoint, checkIntervalSeconds: 300, isEnabled: true)
}

/// Issue #3: "NFS says mount failed but the list shows it mounted". The path is mounted — by SMB.
func testMountStateDoesNotTreatForeignMountAtSamePathAsMounted() throws {
    let nfs = volume(.nfs, server: "192.168.3.106", remote: "video", at: "/Users/andy/Volumes/video")
    let smb = volume(.smb, server: "192.168.3.106", remote: "video", at: "/Users/andy/Volumes/video")
    let state = mountedState(issue3MountOutput)

    try expect(!state.isMounted(config: nfs), "An SMB mount sitting on the NFS volume's mount point must not make the NFS volume look mounted")
    try expect(state.isMounted(config: smb), "The SMB volume really is mounted at its mount point")
}

func testMountStateRequiresTheSameServerNotJustTheSameShareName() throws {
    // 192.168.3.100 also has a "video" share, mounted by Finder at /Volumes/video.
    let state = mountedState(issue3MountOutput)
    let wrongServer = volume(.smb, server: "192.168.3.100", remote: "video", at: "/Users/andy/Volumes/video")
    try expect(!state.isMounted(config: wrongServer), "Same share name on a different server is a different volume")
}

func testMountStateMatchesShareNamesExactly() throws {
    let state = mountedState(issue3MountOutput)
    // "home" must not match "homes", and "homes" must not match "home".
    let home100 = volume(.smb, server: "192.168.3.100", remote: "home", at: "/Volumes/homes")
    try expect(!state.isMounted(config: home100), "'home' must not be satisfied by the 'homes' share")
    let homes106 = volume(.smb, server: "192.168.3.106", remote: "homes", at: "/Volumes/homes-1")
    try expect(state.isMounted(config: homes106), "'homes' on 106 is mounted at /Volumes/homes-1")
    let homes106Elsewhere = volume(.smb, server: "192.168.3.106", remote: "homes", at: "/Users/andy/Volumes/homes")
    try expect(!state.isMounted(config: homes106Elsewhere), "A share mounted somewhere else is not mounted at this volume's mount point")
}

func testMountStateIgnoresShareNameAppearingInTheMountPointPath() throws {
    let output = "//anweining@192.168.3.100/homes on /Users/andy/Volumes/video (smbfs, nodev, nosuid, mounted by andy)\n"
    let video = volume(.smb, server: "192.168.3.100", remote: "video", at: "/Users/andy/Volumes/video")
    try expect(!mountedState(output).isMounted(config: video), "Only the share in the mount *source* counts, not text in the mount point path")
}

func testMountStateDoesNotConfuseHostsThatShareAPrefix() throws {
    let output = "//u@192.168.3.100/video on /Users/andy/Volumes/video (smbfs, nodev, nosuid, mounted by andy)\n"
    let video = volume(.smb, server: "192.168.3.10", remote: "video", at: "/Users/andy/Volumes/video")
    try expect(!mountedState(output).isMounted(config: video), "192.168.3.10 is not 192.168.3.100")
}

func testMountStateNFSMountMatchesByExportPath() throws {
    let output = "192.168.3.106:/video on /Users/andy/Volumes/video (nfs, nodev, nosuid, mounted by andy)\n"
    let nfs = volume(.nfs, server: "192.168.3.106", remote: "video", at: "/Users/andy/Volumes/video")
    let other = volume(.nfs, server: "192.168.3.106", remote: "music", at: "/Users/andy/Volumes/video")
    try expect(mountedState(output).isMounted(config: nfs), "A real NFS mount of the configured export is mounted")
    try expect(!mountedState(output).isMounted(config: other), "A different export is not mounted")
}

func testMountStateWebDAVIsMatchedWhereverTheSystemMountedIt() throws {
    let output = "https://mei@dav.example.com/dav/files on /Volumes/files (webdav, nodev, nosuid, mounted by mei)\n"
    let dav = volume(.webdav, server: "https://dav.example.com", remote: "dav/files", at: "/Users/x/Volumes/files")
    try expect(mountedState(output).isMounted(config: dav), "WebDAV mount points are chosen by the system, so any matching mount counts")
    let otherPath = volume(.webdav, server: "https://dav.example.com", remote: "dav/other", at: "/Users/x/Volumes/files")
    try expect(!mountedState(output).isMounted(config: otherPath), "A different WebDAV path is a different volume")
}

func testMountStateSMBWithSubpathUsesTheBackingMountPoint() throws {
    var zhen = volume(.smb, server: "192.168.3.100", remote: "homes/lixiaozhen/autoprint", at: "/Users/andy/Volumes/zhen")
    zhen.id = UUID(uuidString: "3472E3A1-F4F7-419E-AA48-15417AC9BDAB")!
    let output = "//anweining@192.168.3.100/homes on /Users/andy/Volumes/.AutoVolumeBacking/3472E3A1-F4F7-419E-AA48-15417AC9BDAB (smbfs, nodev, nosuid, mounted by andy)\n"
    try expect(mountedState(output).isMounted(config: zhen), "A subpath SMB volume is mounted at its .AutoVolumeBacking directory, matched by the share (first path component)")
}

func testMountStateEmptySMBRemotePathMatchesAnyShareOnTheServer() throws {
    let output = "//user@nas.example.test/share on /Users/example/Volumes/Router (smbfs, nodev, nosuid, mounted by user)\n"
    let server = volume(.smb, server: "nas.example.test", remote: "", at: "/Users/example/Volumes/Router")
    try expect(mountedState(output).isMounted(config: server), "An empty SMB remote path keeps matching any share on the server")
}

func testSystemMountTableMatchesServerMounts() throws {
    let output = """
    //user@nas.example.test/share on /Volumes/share (smbfs, nodev, nosuid, mounted by user)
    https://mei@example.com/dav/files on /Volumes/DAV (webdav, nodev, nosuid, mounted by xiaoan)
    """
    let smb = VolumeConfig(name: "Router", protocolType: .smb, server: "nas.example.test", remotePath: "", username: "user", mountPoint: "/Users/example/Volumes/", checkIntervalSeconds: 240, isEnabled: true)
    let smbShare = VolumeConfig(name: "RouterShare", protocolType: .smb, server: "smb://nas.example.test", remotePath: "share", username: "user", mountPoint: "/Users/example/Volumes/", checkIntervalSeconds: 240, isEnabled: true)
    let webdav = VolumeConfig(name: "DAV", protocolType: .webdav, server: "https://example.com", remotePath: "dav/files", username: "mei", mountPoint: "/Volumes/DAV", checkIntervalSeconds: 240, isEnabled: true)
    let table = SystemMountTable(mountOutput: output)

    try expect(table.contains(config: smb), "Empty SMB remote path should match an existing server mount")
    try expect(table.contains(config: smbShare), "SMB remote share should match an existing share mount")
    try expect(table.contains(config: webdav), "WebDAV path should match an existing WebDAV mount")
    try expect(table.mountPoint(for: webdav) == "/Volumes/DAV", "WebDAV mounted path should be discoverable from the mount table")
}

func testFinderRevealPlanning() throws {
    let output = """
    https://mei@example.com/video/ on /Volumes/video (webdav, nodev, nosuid, mounted by xiaoan)
    """
    let webdav = VolumeConfig(name: "B", protocolType: .webdav, server: "https://example.com", remotePath: "video", username: "mei", mountPoint: "/Users/example/Volumes/B", checkIntervalSeconds: 60, isEnabled: true)
    let planner = MountPlanner()
    let resolvedPath = planner.resolvedBrowsePath(for: webdav, mountTable: SystemMountTable(mountOutput: output))
    try expect(resolvedPath == "/Volumes/video", "WebDAV Finder reveal should use the real mounted path from the system mount table")

    let revealPlan = planner.finderRevealPlan(for: webdav, resolvedBrowsePath: resolvedPath)
    try expect(revealPlan == CommandPlan(executable: "/usr/bin/open", arguments: ["/Volumes/video"]), "Finder reveal should use open instead of fragile Finder AppleScript")
}

func testCheckScheduler() throws {
    let id = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    var scheduler = CheckScheduler()

    try expect(scheduler.isDue(volumeID: id, interval: 300, now: Date(timeIntervalSince1970: 1_000)), "Unseen volume should be due")
    scheduler.markChecked(volumeID: id, at: Date(timeIntervalSince1970: 1_000))
    try expect(!scheduler.isDue(volumeID: id, interval: 300, now: Date(timeIntervalSince1970: 1_299)), "Volume should not be due before interval")
    try expect(scheduler.isDue(volumeID: id, interval: 300, now: Date(timeIntervalSince1970: 1_300)), "Volume should be due after interval")
}

func testAlertStore() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AlertStore(directory: directory)
    let id = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

    try store.record(volumeID: id, volumeName: "NAS", message: "Mount failed", date: Date(timeIntervalSince1970: 2_000))
    let alerts = try store.load()
    try expect(alerts == [VolumeAlert(volumeID: id, volumeName: "NAS", message: "Mount failed", date: Date(timeIntervalSince1970: 2_000))], "AlertStore should save alerts")

    try store.resolve(volumeID: id)
    let resolvedAlerts = try store.load()
    try expect(resolvedAlerts == [], "AlertStore should resolve alerts")
}

private struct LegacyVolumeAlert: Codable {
    var volumeID: UUID
    var volumeName: String
    var message: String
    var date: Date
}

func testVolumeAlertDecodesLegacyJSONWithoutKeyFieldsAndLocalizedMessageFallsBackToMessage() throws {
    let legacy = LegacyVolumeAlert(
        volumeID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
        volumeName: "NAS",
        message: "Mount failed",
        date: Date(timeIntervalSince1970: 2_000)
    )
    let data = try JSONEncoder().encode(legacy)
    let decoded = try JSONDecoder().decode(VolumeAlert.self, from: data)
    try expect(decoded.messageKey == nil, "Legacy alert JSON without key fields should decode with a nil messageKey")
    try expect(decoded.messageArgs == nil, "Legacy alert JSON without key fields should decode with nil messageArgs")
    try expect(decoded.localizedMessage == decoded.message, "Without a key, localizedMessage should fall back to the stored message")
}

func testAlertStoreRecordWithKeyLocalizesToEveryLanguageAndStoresEnglishMessage() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AlertStore(directory: directory)
    let id = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

    try store.record(volumeID: id, volumeName: "MyDisk", key: .alertNTFSInstallFailed, args: ["MyDisk"], date: Date(timeIntervalSince1970: 3_000))
    let alert = try store.load().first!

    try expect(alert.message.contains("MyDisk"), "The stored message should be the English rendering")
    try expect(alert.message == L10n.t(.alertNTFSInstallFailed, args: ["MyDisk"], in: .en), "The stored message should exactly match the English rendering of the key")

    let previousLanguage = L10n.language
    defer { L10n.setLanguage(previousLanguage) }
    for language: AppLanguage in [.chinese, .english, .korean, .japanese, .russian] {
        L10n.setLanguage(language)
        try expect(alert.localizedMessage.contains("MyDisk"), "localizedMessage for \(language) should contain the volume name arg")
    }
}

/// Minor (final review, controller ruling): `localizedMessage`'s doc comment says it falls back
/// to the stored English `message` — but before this fix, a `messageKey` that no longer exists
/// in the English table (e.g. this alert was recorded by a newer app version, then the user
/// downgraded to one that dropped the key) fell through to `L10n.t`, which itself falls back to
/// returning the raw dotted key string, not the stored message. Simulates a downgrade by
/// decoding a `VolumeAlert` whose `messageKey` was never a real key.
func testAlertStoreLocalizedMessageFallsBackToStoredMessageForUnknownKey() throws {
    let alert = VolumeAlert(
        volumeID: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
        volumeName: "NAS",
        message: "NTFS drive failed to mount (future app version's wording).",
        date: Date(timeIntervalSince1970: 4_000),
        messageKey: "alert.ntfs.futureFailureModeNotYetInvented",
        messageArgs: ["NAS"]
    )

    try expect(alert.localizedMessage == alert.message, "An unrecognized messageKey (e.g. after downgrading) must fall back to the stored English message, not the raw key string")
    try expect(alert.localizedMessage != "alert.ntfs.futureFailureModeNotYetInvented", "localizedMessage must never leak the raw dotted key into the UI")
}

func testAutoVolumeLoggerWritesLocalTimeZone() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let logger = AutoVolumeLogger(directory: directory)
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    logger.write(level: "INFO", message: "tz check", date: date)

    let localFormatter = ISO8601DateFormatter()
    localFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    localFormatter.timeZone = .current
    let expectedPrefix = localFormatter.string(from: date)
    let logText = try String(contentsOf: logger.logFileURL, encoding: .utf8)
    try expect(logText.hasPrefix(expectedPrefix), "Logger should write timestamps in the local time zone, expected prefix \(expectedPrefix) in \(logText)")
}

func testAppSettingsStoreDefaultsAndRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONAppSettingsStore(directory: directory)

    let defaults = try store.load()
    try expect(defaults.logLevel == .info, "Default log level should be info")
    try expect(defaults.openFinderAfterMount == true, "Default openFinderAfterMount should be true")

    let settings = AppSettings(logLevel: .error, openFinderAfterMount: false)
    try store.save(settings)
    let loaded = try store.load()
    try expect(loaded == settings, "AppSettingsStore should round-trip saved settings")
}

func testAppSettingsDecodesLegacyJSONWithoutNTFSField() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let legacyJSON = """
    {"logLevel":0,"openFinderAfterMount":true}
    """
    try legacyJSON.write(to: directory.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    let store = JSONAppSettingsStore(directory: directory)

    let settings = try store.load()

    try expect(settings.autoMountNTFSReadWrite == false, "Legacy settings.json without the field should default autoMountNTFSReadWrite to false")
}

func testAppSettingsRoundTripsNTFSSetting() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONAppSettingsStore(directory: directory)

    try store.save(AppSettings(autoMountNTFSReadWrite: true))
    let loaded = try store.load()

    try expect(loaded.autoMountNTFSReadWrite == true, "autoMountNTFSReadWrite did not round trip through JSON")
}

func testAutoVolumeLoggerFiltersByLogLevel() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsStore = JSONAppSettingsStore(directory: directory)
    try settingsStore.save(AppSettings(logLevel: .warning))
    let logger = AutoVolumeLogger(directory: directory, settingsStore: settingsStore)

    logger.info("info message")
    logger.warning("warning message")
    logger.error("error message")

    let logText = try String(contentsOf: logger.logFileURL, encoding: .utf8)
    try expect(!logText.contains("info message"), "Logger should suppress messages below the configured level")
    try expect(logText.contains("warning message"), "Logger should keep messages at the configured level")
    try expect(logText.contains("error message"), "Logger should keep messages above the configured level")
}

func testLoggerWritesToNamedFileInGivenDirectoryAndKeepsSettingsElsewhere() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let logs = root.appendingPathComponent("Logs")
    let logger = AutoVolumeLogger(directory: logs, fileName: "NTFS.log", settingsDirectory: root)
    logger.info("NTFS disk appeared bsd=disk4s1")
    try expect(logger.logFileURL.path == logs.appendingPathComponent("NTFS.log").path, "logger must write Logs/NTFS.log")
    let text = try String(contentsOf: logger.logFileURL, encoding: .utf8)
    try expect(text.contains("NTFS disk appeared bsd=disk4s1"), "NTFS line missing")
    try expect(!FileManager.default.fileExists(atPath: logs.appendingPathComponent("settings.json").path), "settings must not move into Logs/")
}

func testLegacyLogMigratesIntoLogsDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "old line\n".write(to: root.appendingPathComponent("AutoVolume.log"), atomically: true, encoding: .utf8)
    AutoVolumeLogger.migrateLegacyLogIfNeeded(appSupportDirectory: root)
    try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("AutoVolume.log").path), "legacy log must be moved")
    let moved = try String(contentsOf: root.appendingPathComponent("Logs/AutoVolume.log"), encoding: .utf8)
    try expect(moved.contains("old line"), "legacy content must survive migration")
}

func testPhaseTimerLogsEachPhaseWithOperationName() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let logger = AutoVolumeLogger(directory: directory)
    let timer = PhaseTimer(operation: "webdav-mount home", logger: logger)
    timer.mark("connectivity")
    timer.mark("mount-command")
    timer.finish(result: "success")
    let log = try String(contentsOf: logger.logFileURL, encoding: .utf8)
    try expect(log.contains("webdav-mount home phase=connectivity ms="), "connectivity phase missing")
    try expect(log.contains("webdav-mount home phase=mount-command ms="), "mount-command phase missing")
    try expect(log.contains("webdav-mount home finished result=success total_ms="), "finish line missing")
}

func testDiagnosticsContextTracksCurrentOperation() throws {
    let context = DiagnosticsContext()
    try expect(context.current == nil, "No operation initially")
    context.begin("webdav-mount home")
    try expect(context.current == "webdav-mount home", "begin sets current")
    context.end()
    try expect(context.current == nil, "end clears current")
}

func testDiagnosticsExporterBundlesLogsAndRedactsSecrets() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let appLog = root.appendingPathComponent("AutoVolume.log")
    try "2026-09-24T10:00:00.000+08:00 [INFO] mount https://user:hunter2@nas/x\n".write(to: appLog, atomically: true, encoding: .utf8)
    let exporter = DiagnosticsExporter(appLogURL: appLog,
                                       helperLogURL: root.appendingPathComponent("missing-helper.log"),
                                       volumesConfigURL: root.appendingPathComponent("missing-volumes.json"),
                                       unifiedLogWindow: nil)
    let zip = try exporter.export(to: root)
    try expect(FileManager.default.fileExists(atPath: zip.path), "zip not created")
    let unzipped = root.appendingPathComponent("out")
    let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    unzip.arguments = ["-x", "-k", zip.path, unzipped.path]; try unzip.run(); unzip.waitUntilExit()
    let files = try FileManager.default.subpathsOfDirectory(atPath: unzipped.path)
    try expect(files.contains { $0.hasSuffix("AutoVolume.log") }, "app log missing from bundle")
    try expect(files.contains { $0.hasSuffix("environment.txt") }, "environment.txt missing")
    let bundledLog = try String(contentsOf: unzipped.appendingPathComponent(files.first { $0.hasSuffix("AutoVolume.log") }!), encoding: .utf8)
    try expect(!bundledLog.contains("hunter2"), "password leaked into diagnostics")
}

/// Reproduces "exported unified.log is always empty": the predicate baked into
/// `writeUnifiedLog` used `BEGINS WITH` (with a space), which `/usr/bin/log show` rejects
/// outright ("Bad predicate") on this machine's macOS version — valid NSPredicate syntax is
/// `BEGINSWITH`, no space. The command failed near-instantly, and because `writeUnifiedLog`
/// never checked the exit status or read stderr, the failure was silently swallowed and an
/// empty `unified.log` got zipped up as if everything had gone fine. This runs the exporter
/// against the real `/usr/bin/log show` (this class only ever calls the real binary — there's
/// no injectable runner for it) with a short window and checks the predicate is at least
/// accepted, rather than asserting on log content, which depends on what happens to be in the
/// system log during the test run.
func testDiagnosticsExporterUnifiedLogPredicateIsAccepted() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let appLog = root.appendingPathComponent("AutoVolume.log")
    try "2026-09-24T10:00:00.000+08:00 [INFO] test\n".write(to: appLog, atomically: true, encoding: .utf8)
    let exporter = DiagnosticsExporter(appLogURL: appLog,
                                       helperLogURL: root.appendingPathComponent("missing-helper.log"),
                                       volumesConfigURL: root.appendingPathComponent("missing-volumes.json"),
                                       unifiedLogWindow: "1m")
    let zip = try exporter.export(to: root)
    let unzipped = root.appendingPathComponent("out")
    let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    unzip.arguments = ["-x", "-k", zip.path, unzipped.path]; try unzip.run(); unzip.waitUntilExit()
    let files = try FileManager.default.subpathsOfDirectory(atPath: unzipped.path)
    guard let unifiedLogPath = files.first(where: { $0.hasSuffix("unified.log") }) else {
        throw ManualTestFailure.failed("unified.log missing from bundle")
    }
    let unifiedLog = try String(contentsOf: unzipped.appendingPathComponent(unifiedLogPath), encoding: .utf8)
    try expect(!unifiedLog.contains("Bad predicate"), "log show rejected the predicate: \(unifiedLog)")
}

func testL10nEveryKeyExistsInAllLanguages() throws {
    for language in [ResolvedLanguage.zh, .en, .ko, .ja, .ru] {
        let table = L10n.table(language)
        for key in L10n.allKeys {
            try expect(!(table[key] ?? "").isEmpty, "\(language.rawValue) missing key \(key)")
        }
    }
}

func testL10nPlaceholdersMatchEnglish() throws {
    let english = L10n.table(.en)
    func placeholders(_ s: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%\\d+\\$@")
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }.sorted()
    }
    for language in [ResolvedLanguage.zh, .ko, .ja, .ru] {
        for (key, value) in L10n.table(language) {
            try expect(placeholders(value) == placeholders(english[key] ?? ""), "\(language.rawValue) placeholder mismatch for \(key)")
        }
    }
}

func testResolvedLanguageFromSystemCodes() throws {
    try expect(ResolvedLanguage.resolve(.system, systemLanguageCode: "zh") == .zh, "zh")
    try expect(ResolvedLanguage.resolve(.system, systemLanguageCode: "ja") == .ja, "ja")
    try expect(ResolvedLanguage.resolve(.system, systemLanguageCode: "ko") == .ko, "ko")
    try expect(ResolvedLanguage.resolve(.system, systemLanguageCode: "ru") == .ru, "ru")
    try expect(ResolvedLanguage.resolve(.system, systemLanguageCode: "de") == .en, "de falls back to en")
    try expect(ResolvedLanguage.resolve(.korean, systemLanguageCode: "zh") == .ko, "explicit choice wins")
}

func testL10nFallsBackToEnglishThenKey() throws {
    try expect(L10n.t(L10nKey(rawValue: "no.such.key"), args: [], in: .ja) == "no.such.key", "unknown key returns key")
    try expect(L10n.t(.settingsLanguage, args: [], in: .zh) == "语言", "zh settings.language")
    try expect(L10n.t(.settingsLanguage, args: [], in: .en) == "Language", "en settings.language")
}

/// Controller ruling: `L10n.t` must never crash when fewer args are supplied than the format
/// has placeholders — `String(format:)` with positional `%n$@` reads directly into the array by
/// index, so short arrays are undefined behavior/a crash, not a graceful no-op. `alert.ntfs.mountFailed`
/// (`%1$@ %2$@` in every table) is used as a real two-placeholder key rather than a throwaway
/// test-only one.
func testL10nPadsMissingPositionalArgsInsteadOfCrashing() throws {
    let oneArgResult = L10n.t(.alertNTFSMountFailed, args: ["MyDisk"], in: .en)
    try expect(oneArgResult.contains("MyDisk"), "Supplying only 1 of 2 positional args should not crash and should still contain the supplied arg")

    // Zero args against a placeholder-bearing key must not leak literal "%1$@"/"%2$@" into the
    // result — it must be fully formatted, with every placeholder replaced by "".
    let englishTemplate = L10n.table(.en)["alert.ntfs.mountFailed"]!
    let expectedZeroArgsResult = englishTemplate
        .replacingOccurrences(of: "%1$@", with: "")
        .replacingOccurrences(of: "%2$@", with: "")
    // Pin the resolved language deterministically via the public `t(_:args:)` overload (what
    // real callers use), rather than relying on the test machine's system locale.
    let previousLanguageForZeroArgsCheck = L10n.language
    L10n.setLanguage(.english)
    let zeroArgsResult = L10n.t(.alertNTFSMountFailed, args: [])
    L10n.setLanguage(previousLanguageForZeroArgsCheck)
    try expect(!zeroArgsResult.isEmpty, "Calling t(_:args:) with zero args against a key that requires args should still return safely, not crash")
    try expect(!zeroArgsResult.contains("%"), "Zero args against a placeholder-bearing key must not leak a literal \"%1$@\"/\"%2$@\" into the result")
    try expect(zeroArgsResult == expectedZeroArgsResult, "Zero args should format the English template with every placeholder replaced by an empty string")

    // A key with NO positional placeholders (`settings.language` — no "%" at all in any table)
    // must return the raw template unchanged when called with zero args.
    let noPlaceholderResult = L10n.t(.settingsLanguage, args: [], in: .en)
    try expect(noPlaceholderResult == "Language", "A key with no placeholders should return its template unchanged with zero args")
}

func testAppSettingsDecodesLegacyJSONWithoutLanguageField() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let legacyJSON = """
    {"logLevel":0,"openFinderAfterMount":true}
    """
    try legacyJSON.write(to: directory.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    let store = JSONAppSettingsStore(directory: directory)

    let settings = try store.load()

    try expect(settings.language == .system, "Settings without a language field should default to .system")
    try expect(settings.languageWasPresent == false, "languageWasPresent should be false when the language key is missing")
}

func testAppSettingsLanguageRoundTripsForEachCase() throws {
    for language in AppLanguage.allCases {
        let settings = AppSettings(language: language)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        try expect(decoded.language == language, "AppSettings.language did not round trip for \(language)")
        try expect(decoded.languageWasPresent == true, "languageWasPresent should be true once a language key was decoded")
    }
}

func testLanguageMigrationMapsLegacyChineseValueWhenLanguageFieldMissing() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let legacyJSON = """
    {"logLevel":0,"openFinderAfterMount":true}
    """
    try legacyJSON.write(to: directory.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    let decodedWithoutLanguage = try JSONAppSettingsStore(directory: directory).load()

    let migrated = LanguageMigration.migrate(settings: decodedWithoutLanguage, legacyValue: "chinese")

    try expect(migrated?.language == .chinese, "Migration should map the legacy \"chinese\" value to AppLanguage.chinese")
}

func testLanguageMigrationReturnsNilWithoutLegacyValue() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let legacyJSON = """
    {"logLevel":0,"openFinderAfterMount":true}
    """
    try legacyJSON.write(to: directory.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    let decodedWithoutLanguage = try JSONAppSettingsStore(directory: directory).load()

    let migrated = LanguageMigration.migrate(settings: decodedWithoutLanguage, legacyValue: nil)

    try expect(migrated == nil, "Migration should return nil when there is no legacy UserDefaults value")
}

func testLanguageMigrationReturnsNilWhenLanguageWasAlreadyPresent() throws {
    let settings = AppSettings(language: .english)

    let migrated = LanguageMigration.migrate(settings: settings, legacyValue: "chinese")

    try expect(migrated == nil, "Migration should return nil once settings.json already has a language field")
}

/// Important 2 (final review): a missing `settings.json` (the case for a user who picked a
/// language in 0.1.52 — before the `language` field existed — but never opened Settings again
/// since upgrading, so no settings.json was ever written) must still let `LanguageMigration`
/// run. Previously `JSONAppSettingsStore.load()` returned a fresh `AppSettings()` for a missing
/// file, which defaults `languageWasPresent` to `true` — the exact same value as a settings.json
/// that legitimately has no legacy language to migrate — so `LanguageMigration.migrate` always
/// bailed out via its `guard !settings.languageWasPresent` for these users.
func testLanguageMigrationRunsWhenSettingsFileIsMissingEntirely() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    // Deliberately do NOT create `directory` or write any settings.json into it — this is the
    // "never opened Settings since upgrading" case, not the "settings.json predates the
    // language field" case (which is covered by testAppSettingsDecodesLegacyJSONWithoutLanguageField).
    let store = JSONAppSettingsStore(directory: directory)

    let loaded = try store.load()
    try expect(loaded.languageWasPresent == false, "Loading with no settings.json at all must still report languageWasPresent == false so migration runs")

    let migrated = LanguageMigration.migrate(settings: loaded, legacyValue: "english")
    try expect(migrated?.language == .english, "Migration should map the legacy \"english\" UserDefaults value to AppLanguage.english even when settings.json never existed")

    try store.save(migrated!)
    let reloaded = try store.load()
    try expect(reloaded.language == .english, "The migrated language must actually be persisted to disk")
}

func testAppSettingsEqualityIgnoresLanguageWasPresent() throws {
    let freshlyConstructed = AppSettings(language: .chinese)
    try expect(freshlyConstructed.languageWasPresent == true, "AppSettings() should default languageWasPresent to true")

    // Loading from a settings.json that already has the language field set gives
    // languageWasPresent == true too, but via a different code path (decode, not init) — same
    // content, different provenance either way. The real regression case is a missing-file load
    // (languageWasPresent == false); equality must ignore the flag in both directions.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONAppSettingsStore(directory: directory)
    let loadedFromMissingFile = try store.load()

    try expect(loadedFromMissingFile.languageWasPresent == false, "Loading from a missing file should mark languageWasPresent == false")
    try expect(AppSettings() == loadedFromMissingFile, "AppSettings equality must ignore languageWasPresent and compare only actual settings content")
    try expect(freshlyConstructed != loadedFromMissingFile, "Sanity check: settings with a different language must still compare unequal")
}

func testAppSettingsUpdatingPreservesLanguageWhenChangingUnrelatedField() throws {
    let original = AppSettings(logLevel: .info, openFinderAfterMount: true, autoMountNTFSReadWrite: false, language: .chinese)

    let updated = original.updating(logLevel: .error)

    try expect(updated.language == .chinese, "updating(logLevel:) must not reset language back to .system")
    try expect(updated.logLevel == .error, "updating(logLevel:) should apply the requested change")
    try expect(updated.openFinderAfterMount == true, "updating(logLevel:) must not touch unrelated fields")
    try expect(updated.autoMountNTFSReadWrite == false, "updating(logLevel:) must not touch unrelated fields")
}

func testAppSettingsUpdatingCanChangeLanguageDirectly() throws {
    let original = AppSettings(language: .english)

    let updated = original.updating(language: .korean)

    try expect(updated.language == .korean, "updating(language:) should apply the requested language")
    try expect(updated.logLevel == original.logLevel, "updating(language:) must not touch unrelated fields")
}

func testLocalizationFolderCandidatesForEachResolvedLanguage() throws {
    try expect(localizationFolderCandidates(for: .zh) == ["zh_CN"], "zh candidates")
    try expect(localizationFolderCandidates(for: .ja) == ["ja"], "ja candidates")
    try expect(localizationFolderCandidates(for: .ko) == ["ko"], "ko candidates")
    try expect(localizationFolderCandidates(for: .ru) == ["ru"], "ru candidates")
    try expect(localizationFolderCandidates(for: .en) == ["en", "Base"], "en candidates should fall back to Base")
}

private final class ManualClockBox {
    var nanos: UInt64 = 0
}

func testMainThreadPingPongNoStallWhenPongsArrivePromptly() throws {
    let clockBox = ManualClockBox()
    let detector = MainThreadPingPong(thresholdMs: 400, clock: { clockBox.nanos })

    for _ in 0..<5 {
        let tick = detector.tick()
        try expect(tick.stall == nil, "No stall expected while pongs arrive promptly")
        if tick.shouldSendPing {
            clockBox.nanos += 50_000_000 // pong runs 50ms after the ping was sent
            try expect(detector.recordPong() == nil, "A prompt pong must not report a recovery (nothing was ever flagged as stalled)")
        }
        clockBox.nanos += 150_000_000 // advance toward the next tick
    }
}

func testMainThreadPingPongReportsStallOncePastThreshold() throws {
    let clockBox = ManualClockBox()
    let detector = MainThreadPingPong(thresholdMs: 400, clock: { clockBox.nanos })

    let firstTick = detector.tick()
    try expect(firstTick.shouldSendPing, "First tick with no outstanding ping should send one")
    try expect(firstTick.stall == nil, "No stall on the tick that sends the ping")

    // Advance well past the threshold without the pong ever running.
    clockBox.nanos += 900_000_000
    let secondTick = detector.tick()
    try expect(!secondTick.shouldSendPing, "Should not send a second ping while one is outstanding")
    guard let stall = secondTick.stall else {
        throw ManualTestFailure.failed("Expected a stall to be reported once the outstanding ping crossed the threshold")
    }
    try expect(stall.gapMs >= 900, "Stall gap should reflect the elapsed time since the ping was sent, got \(stall.gapMs)")

    // A further tick before the pong arrives must not report the same stall again.
    clockBox.nanos += 100_000_000
    let thirdTick = detector.tick()
    try expect(thirdTick.stall == nil, "Stall should be reported only once until the pong arrives")
}

func testMainThreadPingPongRecoveryDurationMeasuredFromPingSentAt() throws {
    let clockBox = ManualClockBox()
    let detector = MainThreadPingPong(thresholdMs: 400, clock: { clockBox.nanos })

    _ = detector.tick() // sends a ping at t=0
    clockBox.nanos += 900_000_000 // 900ms later, still no pong
    let stallTick = detector.tick()
    try expect(stallTick.stall != nil, "Expected a stall to be reported before recovery")

    clockBox.nanos += 100_000_000 // pong finally runs at t=1000ms
    guard let recovery = detector.recordPong() else {
        throw ManualTestFailure.failed("Expected a recovery event once the pong for a reported stall arrives")
    }
    try expect(recovery.durationMs == 1000, "Recovery duration must be measured from when the ping was sent, got \(recovery.durationMs)")
}

func testMainThreadPingPongLargeTickGapWithoutOutstandingPingIsNotAStall() throws {
    let clockBox = ManualClockBox()
    let detector = MainThreadPingPong(thresholdMs: 400, clock: { clockBox.nanos })

    let firstTick = detector.tick()
    try expect(firstTick.shouldSendPing, "First tick should send a ping")
    clockBox.nanos += 50_000_000
    try expect(detector.recordPong() == nil, "Prompt pong should not report a recovery")

    // Simulate App Nap / timer coalescing: the next tick doesn't fire for a long time,
    // but there is no outstanding ping at that point since the previous one already
    // completed above.
    clockBox.nanos += 5_000_000_000
    let laterTick = detector.tick()
    try expect(laterTick.stall == nil, "A large gap between ticks with no outstanding ping must not be reported as a stall")
    try expect(laterTick.shouldSendPing, "The later tick should still send a fresh ping since none was outstanding")
}

func testMountPlannerShouldOpenFinderAfterMountRespectsSetting() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = VolumeConfig(name: "Team", protocolType: .smb, server: "nas.local", remotePath: "team", username: "mei", mountPoint: "/Volumes/Team", checkIntervalSeconds: 60, isEnabled: true)

    let defaultPlanner = MountPlanner(settingsStore: JSONAppSettingsStore(directory: directory))
    try expect(defaultPlanner.shouldOpenFinderAfterMount(for: config), "Default setting should open Finder after mount")

    let disabledSettingsStore = JSONAppSettingsStore(directory: directory)
    try disabledSettingsStore.save(AppSettings(openFinderAfterMount: false))
    let disabledPlanner = MountPlanner(settingsStore: disabledSettingsStore)
    try expect(!disabledPlanner.shouldOpenFinderAfterMount(for: config), "Disabled setting should not open Finder after mount")
}

func testNTFSDiskClassifierIdentifiesNTFSPersonality() throws {
    try expect(NTFSDiskClassifier.isNTFSFileSystem(personality: "Windows_NTFS") == true, "Windows_NTFS should classify as NTFS")
    try expect(NTFSDiskClassifier.isNTFSFileSystem(personality: "ntfs") == true, "lowercase ntfs should classify as NTFS")
    try expect(NTFSDiskClassifier.isNTFSFileSystem(personality: "Windows_FAT_32") == false, "FAT32 should not classify as NTFS")
    try expect(NTFSDiskClassifier.isNTFSFileSystem(personality: nil) == false, "nil personality should not classify as NTFS")
}

func testNTFSDiskClassifierIgnoresAlreadyMountedByOurDriver() throws {
    try expect(NTFSDiskClassifier.isOwnedByOurDriver(mountedFileSystemName: "fusefs_ntfs") == true, "fusefs_ntfs mounts should be recognized as already ours")
    try expect(NTFSDiskClassifier.isOwnedByOurDriver(mountedFileSystemName: "ntfs") == false, "native read-only ntfs mounts are not yet ours")
    try expect(NTFSDiskClassifier.isOwnedByOurDriver(mountedFileSystemName: nil) == false, "nil mounted filesystem is not ours")
}

func testNTFSVolumeRoundTripsThroughJSON() throws {
    let volume = NTFSVolume(bsdName: "disk4s1", volumeName: "MY USB", devicePath: "/dev/disk4s1", mountPoint: "/Volumes/MY USB", mountedAt: Date(timeIntervalSince1970: 1_700_000_000))

    let data = try JSONEncoder().encode(volume)
    let decoded = try JSONDecoder().decode(NTFSVolume.self, from: data)

    try expect(decoded == volume, "NTFSVolume JSON round trip failed")
}

func testNTFSMountedVolumesStoreAddLoadRemove() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NTFSMountedVolumesStore(directory: directory)

    let missing = try store.load()
    try expect(missing == [], "Missing store should load as empty array")

    let volume = NTFSVolume(bsdName: "disk4s1", volumeName: "USB", devicePath: "/dev/disk4s1", mountPoint: "/Volumes/USB", mountedAt: Date(timeIntervalSince1970: 1_700_000_000))
    try store.add(volume)
    let loaded = try store.load()
    try expect(loaded == [volume], "Added volume did not load back")

    try store.remove(bsdName: "disk4s1")
    let afterRemove = try store.load()
    try expect(afterRemove == [], "Removed volume should no longer be present")
}

func testNTFSMountedVolumesStoreAddReplacesSameBSDName() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NTFSMountedVolumesStore(directory: directory)

    let first = NTFSVolume(bsdName: "disk4s1", volumeName: "USB", devicePath: "/dev/disk4s1", mountPoint: "/Volumes/USB", mountedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let second = NTFSVolume(bsdName: "disk4s1", volumeName: "USB Renamed", devicePath: "/dev/disk4s1", mountPoint: "/Volumes/USB Renamed", mountedAt: Date(timeIntervalSince1970: 1_700_000_100))
    try store.add(first)
    try store.add(second)

    let loaded = try store.load()
    try expect(loaded == [second], "Re-adding the same bsdName should replace, not duplicate")
}

func testNTFSHelperRequestRoundTripsThroughJSON() throws {
    let request = NTFSHelperRequest(action: .mount, devicePath: "/dev/disk4s1", mountPoint: "/Volumes/USB", volumeName: "USB")

    let encoded = try NTFSHelperWireFormat.encode(request)
    let decoded = try NTFSHelperWireFormat.decodeRequest(encoded)

    try expect(decoded == request, "NTFSHelperRequest did not round trip through the wire format")
    try expect(encoded.last == 0x0A, "Encoded request must end with a newline delimiter")
}

func testNTFSHelperResponseRoundTripsThroughJSON() throws {
    let response = NTFSHelperResponse(success: false, message: "mount failed")

    let encoded = try NTFSHelperWireFormat.encode(response)
    let decoded = try NTFSHelperWireFormat.decodeResponse(encoded)

    try expect(decoded == response, "NTFSHelperResponse did not round trip through the wire format")
    try expect(encoded.last == 0x0A, "Encoded response must end with a newline delimiter")
}

func testNTFSHelperResponseRoundTripsRecoveredFromHibernation() throws {
    let response = NTFSHelperResponse(success: true, message: "", recoveredFromHibernation: true)

    let encoded = try NTFSHelperWireFormat.encode(response)
    let decoded = try NTFSHelperWireFormat.decodeResponse(encoded)

    try expect(decoded == response, "NTFSHelperResponse.recoveredFromHibernation did not round trip through the wire format")
    try expect(decoded.recoveredFromHibernation, "Decoded response should preserve recoveredFromHibernation=true")
}

func testNTFSHelperRequestValidatorRejectsMountPointOutsideVolumes() throws {
    let request = NTFSHelperRequest(action: .unmount, mountPoint: "/etc/passwd")

    let error = NTFSHelperRequestValidator.validate(request)

    try expect(error != nil, "A mountPoint outside /Volumes must be rejected")
}

func testNTFSHelperRequestValidatorAcceptsMountPointUnderVolumes() throws {
    let request = NTFSHelperRequest(action: .unmount, mountPoint: "/Volumes/USB")

    let error = NTFSHelperRequestValidator.validate(request)

    try expect(error == nil, "A mountPoint under /Volumes should be accepted, got: \(error ?? "")")
}

func testNTFSHelperRequestValidatorRejectsMountActionWithoutDevicePath() throws {
    let request = NTFSHelperRequest(action: .mount, devicePath: nil, mountPoint: "/Volumes/USB")

    let error = NTFSHelperRequestValidator.validate(request)

    try expect(error != nil, "A mount action without devicePath must be rejected")
}

func testNTFSHelperRequestValidatorAcceptsCheckFullDiskAccessWithoutMountPoint() throws {
    let request = NTFSHelperRequest.checkFullDiskAccess()

    let error = NTFSHelperRequestValidator.validate(request)

    try expect(error == nil, "checkFullDiskAccess has no mountPoint of its own and must not be rejected for lacking one, got: \(error ?? "")")
}

func testNTFSHelperRequestCheckFullDiskAccessRoundTripsThroughJSON() throws {
    let request = NTFSHelperRequest.checkFullDiskAccess()

    let encoded = try NTFSHelperWireFormat.encode(request)
    let decoded = try NTFSHelperWireFormat.decodeRequest(encoded)

    try expect(decoded == request, "checkFullDiskAccess request did not round trip through the wire format")
    try expect(decoded.action == .checkFullDiskAccess, "Decoded action should be .checkFullDiskAccess")
}

func testFullDiskAccessCheckerReportsGrantedWhenHelperSucceeds() throws {
    let client = RecordingHelperClient(responseToReturn: NTFSHelperResponse(success: true))
    let checker = FullDiskAccessChecker(helperClient: client)

    let status = checker.check()

    try expect(status == .granted, "Expected .granted when the helper reports success")
    try expect(client.sentRequests.first?.action == .checkFullDiskAccess, "Checker should send a checkFullDiskAccess request")
}

func testFullDiskAccessCheckerReportsDeniedWithHelperMessage() throws {
    let client = RecordingHelperClient(responseToReturn: NTFSHelperResponse(success: false, message: "Full Disk Access is not granted to com.autovolume.ntfshelper"))
    let checker = FullDiskAccessChecker(helperClient: client)

    let status = checker.check()

    try expect(status == .denied(message: "Full Disk Access is not granted to com.autovolume.ntfshelper"), "Expected .denied with the helper's message, got \(status)")
}

func testFullDiskAccessCheckerReportsNotInstalledWhenHelperUnreachable() throws {
    let client = RecordingHelperClient(responseToReturn: NTFSHelperResponse(success: false, message: "could not connect to NTFSPrivilegedHelper (errno 2)"))
    let checker = FullDiskAccessChecker(helperClient: client)

    let status = checker.check()

    try expect(status == .notInstalled, "A helper that isn't running yet should read as .notInstalled, not .denied, got \(status)")
}

func testNTFSDriverPathsAreUnderPrivilegedHelperTools() throws {
    try expect(NTFSDriverPaths.installDirectory == "/Library/PrivilegedHelperTools/com.autovolume.ntfsdriver", "installDirectory changed unexpectedly")
    try expect(NTFSDriverPaths.ntfs3gExecutablePath == "/Library/PrivilegedHelperTools/com.autovolume.ntfsdriver/ntfs-3g", "ntfs3gExecutablePath changed unexpectedly")
}

func testNTFSMountPlannerUnmountUsesDiskutil() throws {
    let planner = NTFSMountPlanner(ntfs3gPath: NTFSDriverPaths.ntfs3gExecutablePath)

    let plan = planner.unmountReadOnlyPlan(mountPoint: "/Volumes/USB")

    try expect(plan.executable == "/usr/sbin/diskutil", "Unmount plan should use diskutil")
    try expect(plan.arguments == ["unmount", "/Volumes/USB"], "Unmount plan arguments did not match")
}

func testNTFSMountPlannerMountUsesBundledNtfs3g() throws {
    let planner = NTFSMountPlanner(ntfs3gPath: NTFSDriverPaths.ntfs3gExecutablePath)

    let plan = planner.mountReadWritePlan(devicePath: "/dev/disk4s1", mountPoint: "/Volumes/USB", volumeName: nil)

    try expect(plan.executable == NTFSDriverPaths.ntfs3gExecutablePath, "Mount plan should invoke the installed ntfs-3g binary")
    try expect(plan.arguments == ["/dev/disk4s1", "/Volumes/USB", "-olocal", "-oallow_other", "-oauto_xattr", "-onosuid", "-onoexec"], "Mount plan arguments did not match the researched invocation when no volume name is known")
}

/// Reproduces the real-world bug found while testing on macOS 27: without an explicit
/// `-o volname=`, ntfs-3g/FUSE-T names the mount after the mount point's last path component,
/// not the disk's actual name — happening to match today only because DiskArbitration's initial
/// auto-mount path already used the volume's name, not because that's guaranteed. Passing the
/// real volume name explicitly removes that fragile coincidence.
func testNTFSMountPlannerMountSetsVolnameFromVolumeName() throws {
    let planner = NTFSMountPlanner(ntfs3gPath: NTFSDriverPaths.ntfs3gExecutablePath)

    let plan = planner.mountReadWritePlan(devicePath: "/dev/disk4s1", mountPoint: "/Volumes/数据", volumeName: "数据")

    try expect(plan.arguments.contains("-ovolname=数据"), "Mount plan should pass the real volume name as -o volname, got \(plan.arguments)")
}

/// A comma in the volume name would otherwise be misread by libfuse's `-o` parser as the start
/// of a second, bogus option (no escape syntax exists for commas within a single `-o` value).
func testNTFSMountPlannerMountSanitizesCommasInVolumeName() throws {
    let planner = NTFSMountPlanner(ntfs3gPath: NTFSDriverPaths.ntfs3gExecutablePath)

    let plan = planner.mountReadWritePlan(devicePath: "/dev/disk4s1", mountPoint: "/Volumes/My Drive", volumeName: "My,Drive")

    try expect(plan.arguments.contains("-ovolname=My_Drive"), "Comma in volume name should be sanitized, got \(plan.arguments)")
    try expect(!plan.arguments.contains { $0.contains(",") }, "No argument should contain an unsanitized comma, got \(plan.arguments)")
}

func testNTFSMountPlannerMountAppendsRemoveHiberfileWhenRequested() throws {
    let planner = NTFSMountPlanner(ntfs3gPath: NTFSDriverPaths.ntfs3gExecutablePath)

    let plan = planner.mountReadWritePlan(devicePath: "/dev/disk4s1", mountPoint: "/Volumes/USB", volumeName: nil, removeHiberfile: true)

    try expect(plan.arguments.contains("-oremove_hiberfile"), "Retry mount should pass -o remove_hiberfile, got \(plan.arguments)")
}

func testNTFSMountPlannerMountOmitsRemoveHiberfileByDefault() throws {
    let planner = NTFSMountPlanner(ntfs3gPath: NTFSDriverPaths.ntfs3gExecutablePath)

    let plan = planner.mountReadWritePlan(devicePath: "/dev/disk4s1", mountPoint: "/Volumes/USB", volumeName: nil)

    try expect(!plan.arguments.contains("-oremove_hiberfile"), "First mount attempt must not pre-emptively discard the hibernation file, got \(plan.arguments)")
}

/// Exit code 14 is ntfs-3g's documented `NTFS_VOLUME_HIBERNATED` (ntfs-3g.probe(8)) — but only
/// when it actually got far enough to check the volume's hibernation flag. See the type's doc
/// comment for why stderr must also be checked.
func testNTFSMountFailureClassifierRecognizesHibernatedExitCode() throws {
    try expect(NTFSMountFailureClassifier.classify(exitCode: 14, stderr: "Windows is hibernated, refused to mount.") == .hibernated, "Exit code 14 with a genuine hibernation message must classify as hibernated")
}

func testNTFSMountFailureClassifierTreatsOtherExitCodesAsOther() throws {
    try expect(NTFSMountFailureClassifier.classify(exitCode: 0, stderr: "") == .other, "Exit code 0 (success) must not classify as hibernated")
    try expect(NTFSMountFailureClassifier.classify(exitCode: 1, stderr: "") == .other, "An unrelated failure exit code must not classify as hibernated")
    try expect(NTFSMountFailureClassifier.classify(exitCode: 13, stderr: "") == .other, "Exit code 13 (not the documented hibernation code) must not classify as hibernated")
}

/// Reproduces a real, field-observed false positive: ntfs-3g maps a plain device-`open(2)`
/// failure (e.g. `EPERM`) to the same exit code 14 as genuine hibernation, but with stderr
/// starting "Error opening '/dev/diskN': ..." — it never got far enough to read the volume's
/// hibernation flag at all. Classifying this as `.hibernated` would make `-o remove_hiberfile`
/// get tried for a problem it cannot fix, and would tell the user a hibernation-recovery notice
/// that isn't true.
func testNTFSMountFailureClassifierDoesNotTreatDeviceOpenFailureAsHibernated() throws {
    let stderr = "Error opening '/dev/disk4s3': Operation not permitted\nFailed to mount '/dev/disk4s3': Operation not permitted\nThe NTFS partition is in an unsafe state."
    try expect(NTFSMountFailureClassifier.classify(exitCode: 14, stderr: stderr) == .other, "Exit code 14 caused by a device-open failure must not classify as hibernated")
}

func testNTFSDriverInstallerDetectsFUSETInstalledMarker() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let markerPath = directory.appendingPathComponent("uninstall.sh").path
    try "".write(toFile: markerPath, atomically: true, encoding: .utf8)

    let installer = NTFSDriverInstaller(fuseTMarkerPath: markerPath)

    try expect(installer.isFUSETInstalled() == true, "Installer should report FUSE-T installed when the marker file exists")
}

func testNTFSDriverInstallerDetectsFUSETMissingMarker() throws {
    let installer = NTFSDriverInstaller(fuseTMarkerPath: "/tmp/\(UUID().uuidString)/does-not-exist.sh")

    try expect(installer.isFUSETInstalled() == false, "Installer should report FUSE-T not installed when the marker file is missing")
}

func testNTFSDriverInstallerHelperInstalledMatchesDaemonPlistPresence() throws {
    let installer = NTFSDriverInstaller()

    let matchesRealFilesystemState = installer.isHelperInstalled() == FileManager.default.fileExists(atPath: NTFSHelperSocket.daemonPlistInstallPath)

    try expect(matchesRealFilesystemState, "isHelperInstalled() should reflect whether the daemon plist exists on disk")
}

func testNTFSDriverInstallerTreatsMismatchedBuildStampAsNotInstalled() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stamp = directory.appendingPathComponent("installed-build")
    let plist = directory.appendingPathComponent("daemon.plist")
    let installer = NTFSDriverInstaller(fuseTMarkerPath: "/nonexistent", versionStampPath: stamp.path, daemonPlistPath: plist.path)

    try "49".write(to: stamp, atomically: true, encoding: .utf8)
    try expect(!installer.isHelperInstalled(expectedBuild: "49"), "Matching stamp without daemon plist must not count as installed")

    try "x".write(to: plist, atomically: true, encoding: .utf8)
    try expect(!installer.isHelperInstalled(expectedBuild: "50"), "Stamp 49 must not satisfy expected build 50")
    try expect(installer.isHelperInstalled(expectedBuild: "49"), "Matching stamp plus daemon plist counts as installed")
    try expect(installer.isHelperInstalled(), "Legacy isHelperInstalled() still checks plist presence only")

    try FileManager.default.removeItem(at: stamp)
    try expect(!installer.isHelperInstalled(expectedBuild: "49"), "Missing stamp (pre-0.1.50 install) must trigger reinstall")
}

func testNTFSDriverInstallerInstallPlanWritesBuildStamp() throws {
    let plan = NTFSDriverInstaller().installPlan(
        bundledInstallerPkgPath: "/b/fuse-t.pkg", bundledHelperExecutablePath: "/b/helper",
        bundledDaemonPlistPath: "/b/daemon.plist", bundledNTFS3GPath: "/b/ntfs-3g",
        bundledNTFS3GDylibPath: "/b/libntfs-3g.89.dylib", bundledSharedDylibPath: "/b/libAutoVolumeShared.dylib",
        bundleBuild: "50"
    )
    let script = plan.arguments.joined(separator: " ")
    try expect(script.contains("printf '%s' '50' > '\(NTFSDriverPaths.versionStampPath)'"), "Install plan must write build stamp 50")
}

func testNTFSBundledInstallerPathsResolvesBundleBuildFromAppBundle() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let contentsDir = tempDir.appendingPathComponent("Test.app").appendingPathComponent("Contents")
    let resourcesDir = contentsDir.appendingPathComponent("Resources")
    try FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
    let infoPlist: [String: Any] = ["CFBundleVersion": "77"]
    let plistData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
    try plistData.write(to: contentsDir.appendingPathComponent("Info.plist"))
    guard let bundle = Bundle(path: resourcesDir.path) else {
        throw ManualTestFailure.failed("Expected to construct a Bundle for the fake Resources directory")
    }

    let paths = NTFSBundledInstallerPaths(bundle: bundle)

    try expect(paths.bundleBuild == "77", "bundleBuild should be read from the app bundle's CFBundleVersion, two path components above Resources")
}

func testNTFSBundledInstallerPathsFallsBackToZeroWhenAppBundleHasNoVersion() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let resourcesDir = tempDir.appendingPathComponent("Test.app").appendingPathComponent("Contents").appendingPathComponent("Resources")
    try FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
    guard let bundle = Bundle(path: resourcesDir.path) else {
        throw ManualTestFailure.failed("Expected to construct a Bundle for the fake Resources directory")
    }

    let paths = NTFSBundledInstallerPaths(bundle: bundle)

    try expect(paths.bundleBuild == "0", "bundleBuild should fall back to \"0\" when the resolved app bundle has no CFBundleVersion")
}

func testNTFSDriverInstallerBuildsSingleAdminPrivilegedInstallPlan() throws {
    let installer = NTFSDriverInstaller()

    let plan = installer.installPlan(
        bundledInstallerPkgPath: "/Applications/AutoVolume.app/Contents/Resources/NTFSDriver/fuse-t-installer.pkg",
        bundledHelperExecutablePath: "/Applications/AutoVolume.app/Contents/Resources/NTFSPrivilegedHelper",
        bundledDaemonPlistPath: "/Applications/AutoVolume.app/Contents/Resources/com.autovolume.ntfshelper.plist",
        bundledNTFS3GPath: "/Applications/AutoVolume.app/Contents/Resources/NTFSDriver/ntfs-3g",
        bundledNTFS3GDylibPath: "/Applications/AutoVolume.app/Contents/Resources/NTFSDriver/libntfs-3g.89.dylib",
        bundledSharedDylibPath: "/Applications/AutoVolume.app/Contents/Frameworks/libAutoVolumeShared.dylib"
    )

    try expect(plan.executable == "/usr/bin/osascript", "Install plan should run through osascript for a single admin-privileged prompt")
    try expect(plan.arguments.count == 2 && plan.arguments[0] == "-e", "Install plan should be a single osascript -e invocation")
    let script = plan.arguments[1]
    try expect(script.contains("with administrator privileges"), "Install plan must request administrator privileges")
    try expect(script.contains("installer -pkg"), "Install plan must install the bundled FUSE-T pkg")
    try expect(script.contains(NTFSHelperSocket.helperInstallPath), "Install plan must copy the helper to its install path")
    try expect(script.contains(NTFSHelperSocket.daemonPlistInstallPath), "Install plan must copy the LaunchDaemon plist to its install path")
    try expect(script.contains(NTFSDriverPaths.sharedLibraryPath), "Install plan must copy AutoVolumeShared's dylib next to the driver so the standalone helper can load it")
    try expect(script.contains("launchctl bootstrap system"), "Install plan must bootstrap the LaunchDaemon")
    try expect(script.contains("launchctl bootout system"), "Install plan must unload any existing LaunchDaemon registration before bootstrapping, to be idempotent")
    try expect(
        script.range(of: "launchctl bootout")!.lowerBound < script.range(of: "launchctl bootstrap")!.lowerBound,
        "Install plan must bootout the LaunchDaemon before bootstrapping it"
    )

    // Critical 1 (final review): reinstall must not modify live signed binaries in place.
    // bootout must be the very first command (before the FUSE-T installer guard or any
    // cp/mv of a driver artifact), the FUSE-T installer must be skipped when already
    // installed, and every binary/dylib/plist destination must be written atomically via
    // `cp -> .new` then `mv -f` rather than overwritten in place.
    let firstCpRange = script.range(of: "cp '")
    try expect(firstCpRange != nil, "Install plan must copy at least one driver artifact")
    try expect(
        script.range(of: "launchctl bootout")!.lowerBound < firstCpRange!.lowerBound,
        "Install plan must bootout the LaunchDaemon before copying any driver artifact"
    )
    try expect(
        script.contains("[ -f '/Library/Application Support/fuse-t/uninstall.sh' ] || installer -pkg"),
        "Install plan must guard the FUSE-T installer with the marker-file test so it is skipped when already installed"
    )
    try expect(
        script.range(of: "launchctl bootout")!.lowerBound < script.range(of: "installer -pkg")!.lowerBound,
        "Install plan must bootout the LaunchDaemon before running the FUSE-T installer"
    )
    for destination in [
        NTFSDriverPaths.ntfs3gExecutablePath,
        NTFSDriverPaths.ntfs3gDylibPath,
        NTFSDriverPaths.sharedLibraryPath,
        NTFSHelperSocket.helperInstallPath,
        NTFSHelperSocket.daemonPlistInstallPath
    ] {
        try expect(
            script.contains("cp '") && script.contains("'\(destination).new'"),
            "Install plan must copy into a '.new' staging path for \(destination) rather than overwriting it in place"
        )
        try expect(
            script.contains("mv -f '\(destination).new' '\(destination)'"),
            "Install plan must atomically rename the staged '.new' file onto \(destination) via mv -f"
        )
    }
    try expect(
        script.range(of: "launchctl bootstrap system")!.lowerBound < script.range(of: "printf '%s' '0'")!.lowerBound,
        "Install plan must bootstrap the LaunchDaemon before writing the build stamp"
    )
}

func testNTFSDriverInstallerIncludesNewsyslogConfWhenProvided() throws {
    let installer = NTFSDriverInstaller()

    let plan = installer.installPlan(
        bundledInstallerPkgPath: "/Applications/AutoVolume.app/Contents/Resources/NTFSDriver/fuse-t-installer.pkg",
        bundledHelperExecutablePath: "/Applications/AutoVolume.app/Contents/Resources/NTFSPrivilegedHelper",
        bundledDaemonPlistPath: "/Applications/AutoVolume.app/Contents/Resources/com.autovolume.ntfshelper.plist",
        bundledNTFS3GPath: "/Applications/AutoVolume.app/Contents/Resources/NTFSDriver/ntfs-3g",
        bundledNTFS3GDylibPath: "/Applications/AutoVolume.app/Contents/Resources/NTFSDriver/libntfs-3g.89.dylib",
        bundledSharedDylibPath: "/Applications/AutoVolume.app/Contents/Frameworks/libAutoVolumeShared.dylib",
        bundledNewsyslogConfPath: "/Applications/AutoVolume.app/Contents/Resources/com.autovolume.ntfshelper.newsyslog.conf"
    )

    let script = plan.arguments[1]
    try expect(
        script.contains(NTFSHelperSocket.newsyslogConfInstallPath),
        "Install plan must copy the bundled newsyslog.d config to its install path when provided"
    )
    try expect(
        script.contains("com.autovolume.ntfshelper.newsyslog.conf"),
        "Install plan must reference the bundled newsyslog.d source file"
    )
}

func testNTFSDriverInstallerOmitsNewsyslogConfWhenNotProvided() throws {
    let installer = NTFSDriverInstaller()

    let plan = installer.installPlan(
        bundledInstallerPkgPath: "/Applications/AutoVolume.app/Contents/Resources/NTFSDriver/fuse-t-installer.pkg",
        bundledHelperExecutablePath: "/Applications/AutoVolume.app/Contents/Resources/NTFSPrivilegedHelper",
        bundledDaemonPlistPath: "/Applications/AutoVolume.app/Contents/Resources/com.autovolume.ntfshelper.plist",
        bundledNTFS3GPath: "/Applications/AutoVolume.app/Contents/Resources/NTFSDriver/ntfs-3g",
        bundledNTFS3GDylibPath: "/Applications/AutoVolume.app/Contents/Resources/NTFSDriver/libntfs-3g.89.dylib",
        bundledSharedDylibPath: "/Applications/AutoVolume.app/Contents/Frameworks/libAutoVolumeShared.dylib"
    )

    let script = plan.arguments[1]
    try expect(
        !script.contains(NTFSHelperSocket.newsyslogConfInstallPath),
        "Install plan must not reference the newsyslog.d install path when no bundled conf path is given, preserving backward compatibility"
    )
}

func testNTFSHelperClientReturnsFailureWhenSocketMissing() throws {
    let client = NTFSHelperClient(socketPath: "/tmp/\(UUID().uuidString)/does-not-exist.sock")

    let response = client.send(NTFSHelperRequest(action: .unmount, mountPoint: "/Volumes/USB"))

    try expect(response.success == false, "Sending to a non-existent socket should return a failure response, not crash or throw")
}

func testNTFSHelperClientConformsToProtocol() throws {
    let client: NTFSHelperClientProtocol = NTFSHelperClient(socketPath: "/tmp/\(UUID().uuidString)/does-not-exist.sock")

    let response = client.send(NTFSHelperRequest(action: .mount, devicePath: "/dev/disk4s1", mountPoint: "/Volumes/USB"))

    try expect(response.success == false, "NTFSHelperClient should be usable through NTFSHelperClientProtocol")
}

func testNTFSRemountDebouncerSuppressesWithinCooldown() throws {
    let debouncer = NTFSRemountDebouncer(cooldown: 30)
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    try expect(debouncer.shouldProcess(bsdName: "disk4s1", now: start) == true, "First occurrence should be processed")
    debouncer.markProcessed(bsdName: "disk4s1", at: start)
    try expect(debouncer.shouldProcess(bsdName: "disk4s1", now: start.addingTimeInterval(5)) == false, "Re-appearance within the cooldown window should be suppressed")
}

func testNTFSRemountDebouncerAllowsAfterCooldownExpires() throws {
    let debouncer = NTFSRemountDebouncer(cooldown: 30)
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    debouncer.markProcessed(bsdName: "disk4s1", at: start)
    try expect(debouncer.shouldProcess(bsdName: "disk4s1", now: start.addingTimeInterval(31)) == true, "Re-appearance after the cooldown window should be processed (e.g. user re-inserted the drive)")
}

func testNTFSRemountDebouncerTracksDevicesIndependently() throws {
    let debouncer = NTFSRemountDebouncer(cooldown: 30)
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    debouncer.markProcessed(bsdName: "disk4s1", at: start)
    try expect(debouncer.shouldProcess(bsdName: "disk5s1", now: start.addingTimeInterval(1)) == true, "A different device should not be suppressed by another device's cooldown")
}

func testNTFSRemountDebouncerClearAllowsImmediateReprocessing() throws {
    let debouncer = NTFSRemountDebouncer(cooldown: 30)
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    debouncer.markProcessed(bsdName: "disk4s1", at: start)
    try expect(debouncer.shouldProcess(bsdName: "disk4s1", now: start.addingTimeInterval(1)) == false, "Sanity check: should still be suppressed within the cooldown window before clearing")

    debouncer.clear(bsdName: "disk4s1")

    try expect(debouncer.shouldProcess(bsdName: "disk4s1", now: start.addingTimeInterval(1)) == true, "After clear, the same device should be processed immediately even within what would have been the cooldown window")
}

func testNTFSAutoMountServiceRecordsOnboardingAlertWhenSettingDisabled() throws {
    let settingsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let alertsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let volumesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: settingsDirectory)
        try? FileManager.default.removeItem(at: alertsDirectory)
        try? FileManager.default.removeItem(at: volumesDirectory)
    }
    let settingsStore = JSONAppSettingsStore(directory: settingsDirectory)
    try settingsStore.save(AppSettings(autoMountNTFSReadWrite: false))
    let commandRunner = RecordingCommandRunner()
    let helperClient = RecordingHelperClient()
    let alertStore = AlertStore(directory: alertsDirectory)
    let service = NTFSAutoMountService(
        settingsStore: settingsStore,
        driverInstaller: NTFSDriverInstaller(fuseTMarkerPath: "/tmp/\(UUID().uuidString)/missing"),
        helperClient: helperClient,
        mountedVolumesStore: NTFSMountedVolumesStore(directory: volumesDirectory),
        commandRunner: commandRunner,
        alertStore: alertStore,
        logger: AutoVolumeLogger(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    )

    service.handleDiskEligibleForReadWrite(bsdName: "disk4s1", devicePath: "/dev/disk4s1", volumeName: "USB", mountPoint: "/Volumes/USB", filesystemPersonality: "Windows_NTFS", mountedFileSystemName: "ntfs")

    try expect(commandRunner.plans.isEmpty, "No install commands should run while the setting is disabled")
    try expect(helperClient.sentRequests.isEmpty, "No helper requests should be sent while the setting is disabled")
    let alerts = try alertStore.load()
    try expect(alerts.contains { $0.volumeID == NTFSAutoMountService.onboardingAlertID }, "A one-time onboarding alert should be recorded when an NTFS drive is seen with the setting disabled")
    try expect(
        alerts.contains { $0.messageKey == L10nKey.alertNTFSOnboarding.rawValue && $0.messageArgs == ["USB"] },
        "The onboarding alert should be keyed as alertNTFSOnboarding with the volume name as its arg"
    )
}

func testNTFSAutoMountServiceSkipsWhenAlreadyOwnedByOurDriver() throws {
    let settingsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: settingsDirectory) }
    let settingsStore = JSONAppSettingsStore(directory: settingsDirectory)
    try settingsStore.save(AppSettings(autoMountNTFSReadWrite: true))
    let commandRunner = RecordingCommandRunner()
    let helperClient = RecordingHelperClient()
    let service = NTFSAutoMountService(
        settingsStore: settingsStore,
        driverInstaller: NTFSDriverInstaller(fuseTMarkerPath: "/tmp/\(UUID().uuidString)/missing"),
        helperClient: helperClient,
        mountedVolumesStore: NTFSMountedVolumesStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        commandRunner: commandRunner,
        alertStore: AlertStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        logger: AutoVolumeLogger(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    )

    service.handleDiskEligibleForReadWrite(bsdName: "disk4s1", devicePath: "/dev/disk4s1", volumeName: "USB", mountPoint: "/Volumes/USB", filesystemPersonality: "Windows_NTFS", mountedFileSystemName: "fusefs_ntfs")

    try expect(commandRunner.plans.isEmpty, "Disks already mounted by our own driver should not be reprocessed")
    try expect(helperClient.sentRequests.isEmpty, "Disks already mounted by our own driver should not trigger a helper request")
}

func testNTFSAutoMountServiceInstallsDriverThenSendsHelperMountRequest() throws {
    let settingsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let volumesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let markerDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: settingsDirectory)
        try? FileManager.default.removeItem(at: volumesDirectory)
        try? FileManager.default.removeItem(at: markerDirectory)
    }
    let settingsStore = JSONAppSettingsStore(directory: settingsDirectory)
    try settingsStore.save(AppSettings(autoMountNTFSReadWrite: true))
    let markerPath = markerDirectory.appendingPathComponent("uninstall.sh").path
    // marker does not exist yet: installer must run first
    let commandRunner = RecordingCommandRunner()
    let helperClient = RecordingHelperClient(responseToReturn: NTFSHelperResponse(success: true))
    let volumesStore = NTFSMountedVolumesStore(directory: volumesDirectory)
    let service = NTFSAutoMountService(
        settingsStore: settingsStore,
        driverInstaller: NTFSDriverInstaller(fuseTMarkerPath: markerPath),
        helperClient: helperClient,
        mountedVolumesStore: volumesStore,
        commandRunner: commandRunner,
        alertStore: AlertStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        logger: AutoVolumeLogger(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    )

    service.handleDiskEligibleForReadWrite(bsdName: "disk4s1", devicePath: "/dev/disk4s1", volumeName: "USB", mountPoint: "/Volumes/USB", filesystemPersonality: "Windows_NTFS", mountedFileSystemName: "ntfs")

    try expect(commandRunner.plans.count == 1, "Expected exactly the driver install command; got \(commandRunner.plans.count)")
    try expect(commandRunner.plans[0].executable == "/usr/bin/osascript", "The one command run by the Agent should be the driver install")
    try expect(helperClient.sentRequests.count == 1, "Expected exactly one mount request sent to the helper")
    try expect(helperClient.sentRequests[0] == NTFSHelperRequest(action: .mount, devicePath: "/dev/disk4s1", mountPoint: "/Volumes/USB", volumeName: "USB"), "Helper request did not match expected mount request")
    let volumes = try volumesStore.load()
    try expect(volumes.contains { $0.bsdName == "disk4s1" }, "The remounted volume should be recorded in NTFSMountedVolumesStore")
}

/// When the helper's response says it had to recover from a Windows hibernation state, this
/// is a successful mount — the volume is still recorded exactly as any other success — but the
/// service must also surface a distinct, informational alert. Silently discarding a Windows
/// hibernation/Fast-Startup session with no record of it would surprise a user who later can't
/// figure out why their Windows session state disappeared.
func testNTFSAutoMountServiceRecordsInformationalAlertWhenRecoveredFromHibernation() throws {
    let settingsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let volumesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let markerDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let alertsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: settingsDirectory)
        try? FileManager.default.removeItem(at: volumesDirectory)
        try? FileManager.default.removeItem(at: markerDirectory)
        try? FileManager.default.removeItem(at: alertsDirectory)
    }
    let settingsStore = JSONAppSettingsStore(directory: settingsDirectory)
    try settingsStore.save(AppSettings(autoMountNTFSReadWrite: true))
    let markerPath = markerDirectory.appendingPathComponent("uninstall.sh").path
    let helperClient = RecordingHelperClient(responseToReturn: NTFSHelperResponse(success: true, recoveredFromHibernation: true))
    let alertStore = AlertStore(directory: alertsDirectory)
    let service = NTFSAutoMountService(
        settingsStore: settingsStore,
        driverInstaller: NTFSDriverInstaller(fuseTMarkerPath: markerPath),
        helperClient: helperClient,
        mountedVolumesStore: NTFSMountedVolumesStore(directory: volumesDirectory),
        commandRunner: RecordingCommandRunner(),
        alertStore: alertStore,
        logger: AutoVolumeLogger(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    )

    service.handleDiskEligibleForReadWrite(bsdName: "disk4s1", devicePath: "/dev/disk4s1", volumeName: "USB", mountPoint: "/Volumes/USB", filesystemPersonality: "Windows_NTFS", mountedFileSystemName: "ntfs")

    let alerts = try alertStore.load()
    let hibernationAlert = alerts.first { $0.messageKey == L10nKey.alertNTFSHibernationRecovered.rawValue }
    try expect(hibernationAlert != nil, "Expected an informational hibernation-recovered alert; got \(alerts)")
    try expect(hibernationAlert?.volumeName == "USB", "Hibernation-recovered alert should name the affected volume")
}

func testNTFSAutoMountServiceDoesNotRecordVolumeWhenHelperMountFails() throws {
    let settingsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let volumesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: settingsDirectory)
        try? FileManager.default.removeItem(at: volumesDirectory)
    }
    let settingsStore = JSONAppSettingsStore(directory: settingsDirectory)
    try settingsStore.save(AppSettings(autoMountNTFSReadWrite: true))
    let helperClient = RecordingHelperClient(responseToReturn: NTFSHelperResponse(success: false, message: "mount failed"))
    let volumesStore = NTFSMountedVolumesStore(directory: volumesDirectory)
    let commandRunner = RecordingCommandRunner()
    let alertStore = AlertStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let service = NTFSAutoMountService(
        settingsStore: settingsStore,
        driverInstaller: NTFSDriverInstaller(fuseTMarkerPath: "/Library/Application Support/fuse-t/uninstall.sh"),
        helperClient: helperClient,
        mountedVolumesStore: volumesStore,
        commandRunner: commandRunner,
        alertStore: alertStore,
        logger: AutoVolumeLogger(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    )

    service.handleDiskEligibleForReadWrite(bsdName: "disk4s1", devicePath: "/dev/disk4s1", volumeName: "USB", mountPoint: "/Volumes/USB", filesystemPersonality: "Windows_NTFS", mountedFileSystemName: "ntfs")

    let volumes = try volumesStore.load()
    try expect(volumes.isEmpty, "A failed helper mount must not be recorded as an active NTFS volume")
    try expect(
        commandRunner.plans.last == CommandPlan(executable: "/usr/sbin/diskutil", arguments: ["mount", "disk4s1"]),
        "On mount failure, the drive should be remounted natively read-only via diskutil so it isn't left completely unmounted"
    )
    let alerts = try alertStore.load()
    try expect(
        alerts.contains { $0.message.contains("mount failed") },
        "A failed helper mount should record an alert whose message mentions the failure reason"
    )
    try expect(
        alerts.contains { $0.messageKey == L10nKey.alertNTFSMountFailed.rawValue },
        "A failed helper mount should record an alert keyed as alertNTFSMountFailed"
    )
    try expect(
        alerts.contains { $0.messageArgs == ["USB", "mount failed"] },
        "The alertNTFSMountFailed alert should carry the volume name and raw helper message as args"
    )
}

/// Reproduces a real-world failure loop: once a volume's read-write mount fails, macOS's own
/// DiskArbitration keeps firing description-changed events for it (it re-mounts the volume
/// read-only after our failed attempt, which itself is a description change). Without this
/// guard, `NTFSRemountDebouncer`'s 30s cooldown alone would let every one of those events start
/// a fresh attempt — each one unmounting whatever the user is currently browsing at that path,
/// failing again, and getting remounted read-only — indefinitely, for as long as the disk
/// stays inserted. A failed bsdName must be left alone until it's physically removed and
/// reinserted (`handleDiskDisappeared`), not retried on a timer.
func testNTFSAutoMountServiceDoesNotRetryFailedVolumeUntilDiskDisappears() throws {
    let settingsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let volumesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let installStateDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: settingsDirectory)
        try? FileManager.default.removeItem(at: volumesDirectory)
        try? FileManager.default.removeItem(at: installStateDirectory)
    }
    try FileManager.default.createDirectory(at: installStateDirectory, withIntermediateDirectories: true)
    // Simulate a driver that is already fully installed and up to date, so this test exercises
    // only the mount-retry guard it's named for — not `hasAttemptedInstallThisSession`, a
    // separate, session-wide guard against hammering the (mocked) installer, which is orthogonal
    // to whether a specific bsdName should be retried after physical reinsertion.
    let fuseTMarkerPath = installStateDirectory.appendingPathComponent("uninstall.sh").path
    let daemonPlistPath = installStateDirectory.appendingPathComponent("daemon.plist").path
    let versionStampPath = installStateDirectory.appendingPathComponent("installed-build").path
    try Data().write(to: URL(fileURLWithPath: fuseTMarkerPath))
    try Data().write(to: URL(fileURLWithPath: daemonPlistPath))
    try "1".write(toFile: versionStampPath, atomically: true, encoding: .utf8)
    var bundledInstallerPaths = NTFSBundledInstallerPaths()
    bundledInstallerPaths.bundleBuild = "1"

    let settingsStore = JSONAppSettingsStore(directory: settingsDirectory)
    try settingsStore.save(AppSettings(autoMountNTFSReadWrite: true))
    let helperClient = RecordingHelperClient(responseToReturn: NTFSHelperResponse(success: false, message: "mount failed"))
    let volumesStore = NTFSMountedVolumesStore(directory: volumesDirectory)
    let service = NTFSAutoMountService(
        settingsStore: settingsStore,
        driverInstaller: NTFSDriverInstaller(fuseTMarkerPath: fuseTMarkerPath, versionStampPath: versionStampPath, daemonPlistPath: daemonPlistPath),
        helperClient: helperClient,
        mountedVolumesStore: volumesStore,
        commandRunner: RecordingCommandRunner(),
        alertStore: AlertStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        bundledInstallerPaths: bundledInstallerPaths,
        logger: AutoVolumeLogger(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    )

    service.handleDiskEligibleForReadWrite(bsdName: "disk4s3", devicePath: "/dev/disk4s3", volumeName: "数据", mountPoint: "/Volumes/数据", filesystemPersonality: "Windows_NTFS", mountedFileSystemName: "ntfs")
    try expect(helperClient.sentRequests.count == 1, "First attempt should reach the helper")

    // Simulate the OS re-firing description-changed after remounting read-only post-failure —
    // same bsdName, same everything, arriving well past the debouncer's 30s cooldown.
    service.handleDiskEligibleForReadWrite(bsdName: "disk4s3", devicePath: "/dev/disk4s3", volumeName: "数据", mountPoint: "/Volumes/数据", filesystemPersonality: "Windows_NTFS", mountedFileSystemName: "ntfs")
    try expect(helperClient.sentRequests.count == 1, "A bsdName that already failed this session must not be retried automatically")

    // Physically removing and reinserting the disk is the one thing that should re-arm it.
    service.handleDiskDisappeared(bsdName: "disk4s3")
    service.handleDiskEligibleForReadWrite(bsdName: "disk4s3", devicePath: "/dev/disk4s3", volumeName: "数据", mountPoint: "/Volumes/数据", filesystemPersonality: "Windows_NTFS", mountedFileSystemName: "ntfs")
    try expect(helperClient.sentRequests.count == 2, "After the disk disappears and reappears, a fresh attempt should be allowed")
}

func testNTFSAutoMountServiceRecordsAlertAndSkipsHelperWhenInstallFails() throws {
    let settingsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let volumesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let markerDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let alertsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: settingsDirectory)
        try? FileManager.default.removeItem(at: volumesDirectory)
        try? FileManager.default.removeItem(at: markerDirectory)
        try? FileManager.default.removeItem(at: alertsDirectory)
    }
    let settingsStore = JSONAppSettingsStore(directory: settingsDirectory)
    try settingsStore.save(AppSettings(autoMountNTFSReadWrite: true))
    let markerPath = markerDirectory.appendingPathComponent("uninstall.sh").path
    // marker does not exist: installer must run first, and we simulate a declined admin
    // password prompt (osascript reports this via a non-zero exit code).
    let commandRunner = RecordingCommandRunner(result: CommandResult(exitCode: 1, stdout: "", stderr: "User canceled"))
    let helperClient = RecordingHelperClient()
    let alertStore = AlertStore(directory: alertsDirectory)
    let service = NTFSAutoMountService(
        settingsStore: settingsStore,
        driverInstaller: NTFSDriverInstaller(fuseTMarkerPath: markerPath),
        helperClient: helperClient,
        mountedVolumesStore: NTFSMountedVolumesStore(directory: volumesDirectory),
        commandRunner: commandRunner,
        alertStore: alertStore,
        logger: AutoVolumeLogger(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    )

    service.handleDiskEligibleForReadWrite(bsdName: "disk4s1", devicePath: "/dev/disk4s1", volumeName: "USB", mountPoint: "/Volumes/USB", filesystemPersonality: "Windows_NTFS", mountedFileSystemName: "ntfs")

    try expect(commandRunner.plans.count == 1, "Only the install command should have run")
    try expect(helperClient.sentRequests.isEmpty, "The helper must not be contacted when the driver install itself failed or was declined")
    let alerts = try alertStore.load()
    try expect(alerts.contains { $0.volumeID == NTFSAutoMountService.onboardingAlertID }, "A failed/declined install should record an onboarding-style alert")
    try expect(
        alerts.contains { $0.messageKey == L10nKey.alertNTFSInstallFailed.rawValue && $0.messageArgs == ["USB"] },
        "The failed-install alert should be keyed as alertNTFSInstallFailed with the volume name as its arg"
    )

    // A second disk (or the same disk reappearing) must not re-run the install command.
    service.handleDiskEligibleForReadWrite(bsdName: "disk5s1", devicePath: "/dev/disk5s1", volumeName: "USB2", mountPoint: "/Volumes/USB2", filesystemPersonality: "Windows_NTFS", mountedFileSystemName: "ntfs")

    try expect(commandRunner.plans.count == 1, "The install command must not be re-run for the remainder of this NTFSAutoMountService instance's lifetime after a failed attempt")
    try expect(helperClient.sentRequests.isEmpty, "Still no helper contact after the second disk, since the driver was never successfully installed")
}

func testNTFSAutoMountServiceUnmountCleansUpHelperAndDebouncerOnEject() throws {
    let volumesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: volumesDirectory) }
    let volumesStore = NTFSMountedVolumesStore(directory: volumesDirectory)
    try volumesStore.add(NTFSVolume(bsdName: "disk4s1", volumeName: "USB", devicePath: "/dev/disk4s1", mountPoint: "/Volumes/USB", mountedAt: Date()))
    let helperClient = RecordingHelperClient()
    let debouncer = NTFSRemountDebouncer(cooldown: 30)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    debouncer.markProcessed(bsdName: "disk4s1", at: start)
    let service = NTFSAutoMountService(
        settingsStore: JSONAppSettingsStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        driverInstaller: NTFSDriverInstaller(fuseTMarkerPath: "/tmp/\(UUID().uuidString)/missing"),
        helperClient: helperClient,
        mountedVolumesStore: volumesStore,
        commandRunner: RecordingCommandRunner(),
        alertStore: AlertStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        debouncer: debouncer,
        logger: AutoVolumeLogger(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    )

    service.handleDiskDisappeared(bsdName: "disk4s1")

    try expect(helperClient.sentRequests == [NTFSHelperRequest(action: .unmount, mountPoint: "/Volumes/USB")], "Ejecting a tracked NTFS volume should send a best-effort unmount request to the helper")
    let volumes = try volumesStore.load()
    try expect(volumes.isEmpty, "The ejected volume should be removed from the store")
    try expect(debouncer.shouldProcess(bsdName: "disk4s1", now: start.addingTimeInterval(1)) == true, "Ejecting should clear the debouncer's cooldown so a replug within the window is processed")
}

func testNTFSDriverInstallerBuildsUninstallPlan() throws {
    let installer = NTFSDriverInstaller()

    let plan = installer.uninstallPlan()

    try expect(plan.executable == "/usr/bin/osascript", "Uninstall plan should run through osascript")
    let script = plan.arguments[1]
    try expect(script.contains("with administrator privileges"), "Uninstall plan must request administrator privileges")
    try expect(script.contains("launchctl bootout system"), "Uninstall plan must unload the LaunchDaemon")
    try expect(script.contains(NTFSHelperSocket.helperInstallPath), "Uninstall plan must remove the installed helper binary")
    try expect(script.contains(NTFSDriverPaths.installDirectory), "Uninstall plan must remove the driver install directory")
}

struct FakeMountStateProvider: MountStateProvider {
    let isMounted: Bool
    func isMounted(config: VolumeConfig) -> Bool { isMounted }
}

final class RecordingCommandRunner: CommandRunner {
    var plans: [CommandPlan] = []
    let result: CommandResult

    init(result: CommandResult = CommandResult(exitCode: 0, stdout: "", stderr: "")) {
        self.result = result
    }

    func run(_ plan: CommandPlan) throws -> CommandResult {
        plans.append(plan)
        return result
    }
}

final class RecordingHelperClient: NTFSHelperClientProtocol {
    var sentRequests: [NTFSHelperRequest] = []
    private let responseToReturn: NTFSHelperResponse

    init(responseToReturn: NTFSHelperResponse = NTFSHelperResponse(success: true)) {
        self.responseToReturn = responseToReturn
    }

    func send(_ request: NTFSHelperRequest) -> NTFSHelperResponse {
        sentRequests.append(request)
        return responseToReturn
    }
}

final class SequenceCommandRunner: CommandRunner {
    var plans: [CommandPlan] = []
    private var results: [CommandResult]

    init(results: [CommandResult]) {
        self.results = results
    }

    func run(_ plan: CommandPlan) throws -> CommandResult {
        plans.append(plan)
        if results.isEmpty {
            return CommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        return results.removeFirst()
    }
}

func testUpdateScheduleChecksDaily() throws {
    try expect(UpdateSchedule.automaticallyChecks, "Automatic update checks must be on")
    try expect(UpdateSchedule.checkInterval == 86400, "Update check interval must be one day")
}

let tests: [(String, () throws -> Void)] = [
    ("VolumeConfig JSON round trip", testVolumeConfigRoundTripsThroughJSON),
    ("ConfigStore save/load", testConfigStoreSaveLoadAndMissingFile),
    ("InMemoryCredentialStore", testInMemoryCredentialStore),
    ("EncryptedFileCredentialStore", testEncryptedFileCredentialStore),
    ("CommandResult redaction", testCommandResultRedactsPasswords),
    ("SMB dialect preferences", testSMBDialectPreferences),
    ("MountPlanning", testMountPlanning),
    ("ConnectivityPlanning", testConnectivityPlanning),
    ("WebDAV 401 result renders in non-English language", testWebDAVUnauthorizedResultRendersInNonEnglishLanguage),
    ("MountExposure", testMountExposureCreatesSubdirectoryLink),
    ("PathHealthProbe", testPathHealthProbe),
    ("AutoVolumeLogger", testAutoVolumeLoggerRetentionAndSizeLimit),
    ("AutoVolumeLogger write() stays fast as log grows over days", testAutoVolumeLoggerWriteStaysFastAsLogGrowsOverDays),
    ("AutoVolumeLogger first write into huge log stays fast", testAutoVolumeLoggerFirstWriteIntoHugeLogStaysFast),
    ("AutoVolumeLogger prune drops only expired suffix of huge log", testAutoVolumeLoggerPruneDropsOnlyExpiredSuffixOfHugeLog),
    ("AutoVolumeLogger prune keeps undatable lines", testAutoVolumeLoggerPruneKeepsLinesItCannotDate),
    ("ServerHostSet dedupes by hostname and skips disabled", testServerHostSetDedupesByHostnameAndSkipsDisabled),
    ("AgentEngine decisions", testAgentEngineDecisions),
    ("SystemMountTable", testSystemMountTableMatchesServerMounts),
    ("NFS quiet plan uses proven options", testNFSQuietMountPlanUsesTheUsersProvenOptions),
    ("NFS export parsing", testNFSExportParsingReadsTheFirstColumnOfShowmount),
    ("NFS resolver finds full export path from share name", testNFSResolverFindsTheFullExportPathFromAShareName),
    ("NFS resolver leaves correct paths alone", testNFSResolverLeavesCorrectPathsAlone),
    ("NFS resolver lists exports when unmatched or ambiguous", testNFSResolverListsExportsWhenNothingMatchesOrItIsAmbiguous),
    ("NFS diagnosis names exports when path not exported", testNFSDiagnosisNamesTheExportsWhenThePathIsNotExported),
    ("NFS diagnosis blames server rules when path exported", testNFSDiagnosisBlamesTheServerRulesWhenThePathIsExported),
    ("NFS diagnosis separates local from server permission", testNFSDiagnosisSeparatesLocalPermissionFromServerPermission),
    ("NFS diagnosis messages in every language", testNFSDiagnosisMessagesExistInEveryLanguage),
    ("TimedCommand kills a process past its timeout", testTimedCommandKillsAProcessThatOutlivesItsTimeout),
    ("AgentEngine explains an NFS permission denied", testAgentEngineExplainsAnNFSPermissionDenied),
    ("AgentEngine keeps raw text for unrelated NFS errors", testAgentEngineKeepsRawTextForUnrelatedNFSErrors),
    ("NFS diagnosis blames the mount point only outside home", testNFSDiagnosisOnlyBlamesTheMountPointWhenItIsOutsideTheHomeFolder),
    ("Showmount lister refuses the main thread", testShowmountListerRefusesToBlockTheMainThread),
    ("TimedCommand handles large output", testTimedCommandHandlesLargeOutput),
    ("AgentEngine clears a dead mount that blocks mount point preparation", testAgentEngineClearsDeadMountThatBlocksMountPointPreparation),
    ("AgentEngine surfaces an unusable mount point after clearing it", testAgentEngineStillReportsAMountPointThatCannotBePreparedEvenAfterUnmount),
    ("NetworkPathFilter ignores peer-to-peer interface flapping", testNetworkPathFilterIgnoresPeerToPeerInterfaceFlapping),
    ("NetworkPathFilter triggers on real changes", testNetworkPathFilterTriggersOnRealChanges),
    ("NetworkPathFilter ignores interface order", testNetworkPathFilterTreatsInterfaceOrderAsIrrelevant),
    ("StatusTransitionTracker logs only changes", testStatusTransitionTrackerLogsOnlyChanges),
    ("AgentEngine unmounts nothing when nothing is mounted at the failing path", testAgentEngineDoesNotUnmountAnythingWhenNothingIsMountedAtTheFailingPath),
    ("NetworkPathFilter triggers on gateway change", testNetworkPathFilterTriggersWhenTheGatewayChangesOnTheSameInterface),
    ("StatusTransitionTracker notices recovery after unlogged states", testStatusTransitionTrackerNoticesRecoveryAfterUnloggedStates),
    ("SystemMountTable reports unreadable table", testSystemMountTableReportsUnreadableTableInsteadOfEmpty),
    ("MountState handles IPv6 and bracketed hosts", testMountStateHandlesIPv6AndBracketedHosts),
    ("MountState ignores a foreign mount at the same path (NFS vs SMB)", testMountStateDoesNotTreatForeignMountAtSamePathAsMounted),
    ("MountState requires the same server", testMountStateRequiresTheSameServerNotJustTheSameShareName),
    ("MountState matches share names exactly", testMountStateMatchesShareNamesExactly),
    ("MountState ignores share name in mount point path", testMountStateIgnoresShareNameAppearingInTheMountPointPath),
    ("MountState does not confuse hosts sharing a prefix", testMountStateDoesNotConfuseHostsThatShareAPrefix),
    ("MountState NFS matches by export path", testMountStateNFSMountMatchesByExportPath),
    ("MountState WebDAV matched wherever mounted", testMountStateWebDAVIsMatchedWhereverTheSystemMountedIt),
    ("MountState SMB subpath uses backing mount point", testMountStateSMBWithSubpathUsesTheBackingMountPoint),
    ("MountState empty SMB remote path matches any share", testMountStateEmptySMBRemotePathMatchesAnyShareOnTheServer),
    ("FinderRevealPlanning", testFinderRevealPlanning),
    ("CheckScheduler", testCheckScheduler),
    ("AlertStore", testAlertStore),
    ("VolumeAlert decodes legacy JSON without key fields", testVolumeAlertDecodesLegacyJSONWithoutKeyFieldsAndLocalizedMessageFallsBackToMessage),
    ("AlertStore record(key:) localizes to every language and stores English message", testAlertStoreRecordWithKeyLocalizesToEveryLanguageAndStoresEnglishMessage),
    ("AlertStore localizedMessage falls back to stored message for unknown key", testAlertStoreLocalizedMessageFallsBackToStoredMessageForUnknownKey),
    ("AutoVolumeLogger local time zone", testAutoVolumeLoggerWritesLocalTimeZone),
    ("AppSettingsStore", testAppSettingsStoreDefaultsAndRoundTrip),
    ("AppSettings legacy JSON decode", testAppSettingsDecodesLegacyJSONWithoutNTFSField),
    ("AppSettings NTFS setting round trip", testAppSettingsRoundTripsNTFSSetting),
    ("AutoVolumeLogger level filtering", testAutoVolumeLoggerFiltersByLogLevel),
    ("MountPlanner shouldOpenFinderAfterMount", testMountPlannerShouldOpenFinderAfterMountRespectsSetting),
    ("NTFSDiskClassifier NTFS personality", testNTFSDiskClassifierIdentifiesNTFSPersonality),
    ("NTFSDiskClassifier already-mounted filter", testNTFSDiskClassifierIgnoresAlreadyMountedByOurDriver),
    ("NTFSVolume JSON round trip", testNTFSVolumeRoundTripsThroughJSON),
    ("NTFSMountedVolumesStore add/load/remove", testNTFSMountedVolumesStoreAddLoadRemove),
    ("NTFSMountedVolumesStore replaces same bsdName", testNTFSMountedVolumesStoreAddReplacesSameBSDName),
    ("NTFSHelperRequest wire round trip", testNTFSHelperRequestRoundTripsThroughJSON),
    ("NTFSHelperResponse wire round trip", testNTFSHelperResponseRoundTripsThroughJSON),
    ("NTFSHelperResponse wire round trip preserves recoveredFromHibernation", testNTFSHelperResponseRoundTripsRecoveredFromHibernation),
    ("NTFSHelperRequestValidator rejects outside /Volumes", testNTFSHelperRequestValidatorRejectsMountPointOutsideVolumes),
    ("NTFSHelperRequestValidator accepts /Volumes path", testNTFSHelperRequestValidatorAcceptsMountPointUnderVolumes),
    ("NTFSHelperRequestValidator rejects mount without devicePath", testNTFSHelperRequestValidatorRejectsMountActionWithoutDevicePath),
    ("NTFSHelperRequestValidator accepts checkFullDiskAccess without mountPoint", testNTFSHelperRequestValidatorAcceptsCheckFullDiskAccessWithoutMountPoint),
    ("NTFSHelperRequest checkFullDiskAccess wire round trip", testNTFSHelperRequestCheckFullDiskAccessRoundTripsThroughJSON),
    ("FullDiskAccessChecker reports granted", testFullDiskAccessCheckerReportsGrantedWhenHelperSucceeds),
    ("FullDiskAccessChecker reports denied with helper message", testFullDiskAccessCheckerReportsDeniedWithHelperMessage),
    ("FullDiskAccessChecker reports not installed when helper unreachable", testFullDiskAccessCheckerReportsNotInstalledWhenHelperUnreachable),
    ("NTFSDriverPaths constants", testNTFSDriverPathsAreUnderPrivilegedHelperTools),
    ("NTFSMountPlanner unmount uses diskutil", testNTFSMountPlannerUnmountUsesDiskutil),
    ("NTFSMountPlanner mount uses bundled ntfs-3g", testNTFSMountPlannerMountUsesBundledNtfs3g),
    ("NTFSMountPlanner mount sets volname from volumeName", testNTFSMountPlannerMountSetsVolnameFromVolumeName),
    ("NTFSMountPlanner mount sanitizes commas in volume name", testNTFSMountPlannerMountSanitizesCommasInVolumeName),
    ("NTFSMountPlanner mount appends remove_hiberfile when requested", testNTFSMountPlannerMountAppendsRemoveHiberfileWhenRequested),
    ("NTFSMountPlanner mount omits remove_hiberfile by default", testNTFSMountPlannerMountOmitsRemoveHiberfileByDefault),
    ("NTFSMountFailureClassifier recognizes hibernated exit code", testNTFSMountFailureClassifierRecognizesHibernatedExitCode),
    ("NTFSMountFailureClassifier treats other exit codes as other", testNTFSMountFailureClassifierTreatsOtherExitCodesAsOther),
    ("NTFSMountFailureClassifier does not treat device-open failure as hibernated", testNTFSMountFailureClassifierDoesNotTreatDeviceOpenFailureAsHibernated),
    ("NTFSDriverInstaller detects FUSE-T installed marker", testNTFSDriverInstallerDetectsFUSETInstalledMarker),
    ("NTFSDriverInstaller detects FUSE-T missing marker", testNTFSDriverInstallerDetectsFUSETMissingMarker),
    ("NTFSDriverInstaller helper-installed matches daemon plist presence", testNTFSDriverInstallerHelperInstalledMatchesDaemonPlistPresence),
    ("NTFSDriverInstaller treats mismatched build stamp as not installed", testNTFSDriverInstallerTreatsMismatchedBuildStampAsNotInstalled),
    ("NTFSDriverInstaller install plan writes build stamp", testNTFSDriverInstallerInstallPlanWritesBuildStamp),
    ("NTFSBundledInstallerPaths resolves bundleBuild from app bundle", testNTFSBundledInstallerPathsResolvesBundleBuildFromAppBundle),
    ("NTFSBundledInstallerPaths falls back to 0 when app bundle has no version", testNTFSBundledInstallerPathsFallsBackToZeroWhenAppBundleHasNoVersion),
    ("NTFSDriverInstaller builds single admin-privileged install plan", testNTFSDriverInstallerBuildsSingleAdminPrivilegedInstallPlan),
    ("NTFSDriverInstaller includes newsyslog.d conf when provided", testNTFSDriverInstallerIncludesNewsyslogConfWhenProvided),
    ("NTFSDriverInstaller omits newsyslog.d conf when not provided", testNTFSDriverInstallerOmitsNewsyslogConfWhenNotProvided),
    ("NTFSHelperClient returns failure when socket missing", testNTFSHelperClientReturnsFailureWhenSocketMissing),
    ("NTFSHelperClient conforms to NTFSHelperClientProtocol", testNTFSHelperClientConformsToProtocol),
    ("NTFSRemountDebouncer suppresses within cooldown", testNTFSRemountDebouncerSuppressesWithinCooldown),
    ("NTFSRemountDebouncer allows after cooldown", testNTFSRemountDebouncerAllowsAfterCooldownExpires),
    ("NTFSRemountDebouncer tracks devices independently", testNTFSRemountDebouncerTracksDevicesIndependently),
    ("NTFSRemountDebouncer clear allows immediate reprocessing", testNTFSRemountDebouncerClearAllowsImmediateReprocessing),
    ("NTFSAutoMountService onboarding alert when disabled", testNTFSAutoMountServiceRecordsOnboardingAlertWhenSettingDisabled),
    ("NTFSAutoMountService skips already-owned mounts", testNTFSAutoMountServiceSkipsWhenAlreadyOwnedByOurDriver),
    ("NTFSAutoMountService installs driver then sends helper mount request", testNTFSAutoMountServiceInstallsDriverThenSendsHelperMountRequest),
    ("NTFSAutoMountService records informational alert when recovered from hibernation", testNTFSAutoMountServiceRecordsInformationalAlertWhenRecoveredFromHibernation),
    ("NTFSAutoMountService does not record volume when helper mount fails", testNTFSAutoMountServiceDoesNotRecordVolumeWhenHelperMountFails),
    ("NTFSAutoMountService does not retry failed volume until disk disappears", testNTFSAutoMountServiceDoesNotRetryFailedVolumeUntilDiskDisappears),
    ("NTFSAutoMountService records alert and skips helper when install fails", testNTFSAutoMountServiceRecordsAlertAndSkipsHelperWhenInstallFails),
    ("NTFSAutoMountService cleans up helper and debouncer on eject", testNTFSAutoMountServiceUnmountCleansUpHelperAndDebouncerOnEject),
    ("NTFSDriverInstaller builds uninstall plan", testNTFSDriverInstallerBuildsUninstallPlan),
    ("AutoVolumeLogger writes to named file, keeps settings elsewhere", testLoggerWritesToNamedFileInGivenDirectoryAndKeepsSettingsElsewhere),
    ("AutoVolumeLogger migrates legacy log into Logs directory", testLegacyLogMigratesIntoLogsDirectory),
    ("PhaseTimer logs each phase with operation name", testPhaseTimerLogsEachPhaseWithOperationName),
    ("DiagnosticsContext tracks current operation", testDiagnosticsContextTracksCurrentOperation),
    ("DiagnosticsExporter bundles logs and redacts secrets", testDiagnosticsExporterBundlesLogsAndRedactsSecrets),
    ("DiagnosticsExporter unified log predicate is accepted", testDiagnosticsExporterUnifiedLogPredicateIsAccepted),
    ("MainThreadPingPong no stall when pongs arrive promptly", testMainThreadPingPongNoStallWhenPongsArrivePromptly),
    ("MainThreadPingPong reports stall once past threshold", testMainThreadPingPongReportsStallOncePastThreshold),
    ("MainThreadPingPong recovery duration measured from pingSentAt", testMainThreadPingPongRecoveryDurationMeasuredFromPingSentAt),
    ("MainThreadPingPong large tick gap without outstanding ping is not a stall", testMainThreadPingPongLargeTickGapWithoutOutstandingPingIsNotAStall),
    ("UpdateSchedule checks daily", testUpdateScheduleChecksDaily),
    ("L10n every key exists in all languages", testL10nEveryKeyExistsInAllLanguages),
    ("L10n placeholders match English", testL10nPlaceholdersMatchEnglish),
    ("ResolvedLanguage.resolve from system codes", testResolvedLanguageFromSystemCodes),
    ("L10n falls back to English then key", testL10nFallsBackToEnglishThenKey),
    ("L10n pads missing positional args instead of crashing", testL10nPadsMissingPositionalArgsInsteadOfCrashing),
    ("AppSettings decodes legacy JSON without language field", testAppSettingsDecodesLegacyJSONWithoutLanguageField),
    ("AppSettings language round trips for each case", testAppSettingsLanguageRoundTripsForEachCase),
    ("LanguageMigration maps legacy chinese value", testLanguageMigrationMapsLegacyChineseValueWhenLanguageFieldMissing),
    ("LanguageMigration runs when settings.json is missing entirely", testLanguageMigrationRunsWhenSettingsFileIsMissingEntirely),
    ("AppSettings equality ignores languageWasPresent", testAppSettingsEqualityIgnoresLanguageWasPresent),
    ("LanguageMigration returns nil without legacy value", testLanguageMigrationReturnsNilWithoutLegacyValue),
    ("LanguageMigration returns nil when language already present", testLanguageMigrationReturnsNilWhenLanguageWasAlreadyPresent),
    ("AppSettings.updating preserves language when changing unrelated field", testAppSettingsUpdatingPreservesLanguageWhenChangingUnrelatedField),
    ("AppSettings.updating can change language directly", testAppSettingsUpdatingCanChangeLanguageDirectly),
    ("localizationFolderCandidates for each resolved language", testLocalizationFolderCandidatesForEachResolvedLanguage),
    ("ManagedMountPoints uses backing directory for SMB with subpath", testManagedMountPointsUsesBackingDirectoryForSMBWithSubpath),
    ("ManagedMountPoints uses live mount table for WebDAV", testManagedMountPointsUsesLiveMountTableForWebDAV)
]

do {
    for (name, test) in tests {
        try test()
        print("PASS: \(name)")
    }
    print("All manual tests passed (\(tests.count))")
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
