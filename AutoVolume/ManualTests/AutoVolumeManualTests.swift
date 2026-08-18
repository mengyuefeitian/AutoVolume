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

    let nfs = VolumeConfig(name: "NFS", protocolType: .nfs, server: "nas.local", remotePath: "video", username: nil, mountPoint: "/Volumes/NFS", checkIntervalSeconds: 60, isEnabled: true)
    let nfsCheck = ConnectivityTester().checkResult(for: nfs, result: CommandResult(exitCode: 1, stdout: "", stderr: ""))
    try expect(!nfsCheck.isReachable, "NFS failed probe should not be treated as reachable")
    try expect(nfsCheck.message?.contains("port 2049") == true, "NFS failed probe should mention port 2049")
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

let tests: [(String, () throws -> Void)] = [
    ("VolumeConfig JSON round trip", testVolumeConfigRoundTripsThroughJSON),
    ("ConfigStore save/load", testConfigStoreSaveLoadAndMissingFile),
    ("InMemoryCredentialStore", testInMemoryCredentialStore),
    ("EncryptedFileCredentialStore", testEncryptedFileCredentialStore),
    ("CommandResult redaction", testCommandResultRedactsPasswords),
    ("SMB dialect preferences", testSMBDialectPreferences),
    ("MountPlanning", testMountPlanning),
    ("ConnectivityPlanning", testConnectivityPlanning),
    ("MountExposure", testMountExposureCreatesSubdirectoryLink),
    ("PathHealthProbe", testPathHealthProbe),
    ("AutoVolumeLogger", testAutoVolumeLoggerRetentionAndSizeLimit),
    ("AgentEngine decisions", testAgentEngineDecisions),
    ("SystemMountTable", testSystemMountTableMatchesServerMounts),
    ("FinderRevealPlanning", testFinderRevealPlanning),
    ("CheckScheduler", testCheckScheduler),
    ("AlertStore", testAlertStore),
    ("AutoVolumeLogger local time zone", testAutoVolumeLoggerWritesLocalTimeZone),
    ("AppSettingsStore", testAppSettingsStoreDefaultsAndRoundTrip),
    ("AutoVolumeLogger level filtering", testAutoVolumeLoggerFiltersByLogLevel),
    ("MountPlanner shouldOpenFinderAfterMount", testMountPlannerShouldOpenFinderAfterMountRespectsSetting)
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
