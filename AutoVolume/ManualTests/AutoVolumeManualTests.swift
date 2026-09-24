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
    let request = NTFSHelperRequest(action: .mount, devicePath: "/dev/disk4s1", mountPoint: "/Volumes/USB")

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

    let plan = planner.mountReadWritePlan(devicePath: "/dev/disk4s1", mountPoint: "/Volumes/USB")

    try expect(plan.executable == NTFSDriverPaths.ntfs3gExecutablePath, "Mount plan should invoke the installed ntfs-3g binary")
    try expect(plan.arguments == ["/dev/disk4s1", "/Volumes/USB", "-olocal", "-oallow_other", "-oauto_xattr", "-onosuid", "-onoexec"], "Mount plan arguments did not match the researched invocation")
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
    try expect(helperClient.sentRequests[0] == NTFSHelperRequest(action: .mount, devicePath: "/dev/disk4s1", mountPoint: "/Volumes/USB"), "Helper request did not match expected mount request")
    let volumes = try volumesStore.load()
    try expect(volumes.contains { $0.bsdName == "disk4s1" }, "The remounted volume should be recorded in NTFSMountedVolumesStore")
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
    ("AgentEngine decisions", testAgentEngineDecisions),
    ("SystemMountTable", testSystemMountTableMatchesServerMounts),
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
    ("NTFSHelperRequestValidator rejects outside /Volumes", testNTFSHelperRequestValidatorRejectsMountPointOutsideVolumes),
    ("NTFSHelperRequestValidator accepts /Volumes path", testNTFSHelperRequestValidatorAcceptsMountPointUnderVolumes),
    ("NTFSHelperRequestValidator rejects mount without devicePath", testNTFSHelperRequestValidatorRejectsMountActionWithoutDevicePath),
    ("NTFSDriverPaths constants", testNTFSDriverPathsAreUnderPrivilegedHelperTools),
    ("NTFSMountPlanner unmount uses diskutil", testNTFSMountPlannerUnmountUsesDiskutil),
    ("NTFSMountPlanner mount uses bundled ntfs-3g", testNTFSMountPlannerMountUsesBundledNtfs3g),
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
    ("NTFSAutoMountService does not record volume when helper mount fails", testNTFSAutoMountServiceDoesNotRecordVolumeWhenHelperMountFails),
    ("NTFSAutoMountService records alert and skips helper when install fails", testNTFSAutoMountServiceRecordsAlertAndSkipsHelperWhenInstallFails),
    ("NTFSAutoMountService cleans up helper and debouncer on eject", testNTFSAutoMountServiceUnmountCleansUpHelperAndDebouncerOnEject),
    ("NTFSDriverInstaller builds uninstall plan", testNTFSDriverInstallerBuildsUninstallPlan),
    ("AutoVolumeLogger writes to named file, keeps settings elsewhere", testLoggerWritesToNamedFileInGivenDirectoryAndKeepsSettingsElsewhere),
    ("AutoVolumeLogger migrates legacy log into Logs directory", testLegacyLogMigratesIntoLogsDirectory),
    ("PhaseTimer logs each phase with operation name", testPhaseTimerLogsEachPhaseWithOperationName),
    ("DiagnosticsContext tracks current operation", testDiagnosticsContextTracksCurrentOperation),
    ("DiagnosticsExporter bundles logs and redacts secrets", testDiagnosticsExporterBundlesLogsAndRedactsSecrets),
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
    ("localizationFolderCandidates for each resolved language", testLocalizationFolderCandidatesForEachResolvedLanguage)
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
