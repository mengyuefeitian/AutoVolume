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
    let message = "mount_smbfs: mount error: //admin:ZN245107zn@192.168.10.1/%E5%B7%A5%E5%85%B7: No such file or directory"
    let redacted = CommandResult.redacted(message, secrets: ["ZN245107zn"])
    try expect(!redacted.contains("ZN245107zn"), "Command output should redact raw password")
    try expect(redacted.contains("//admin:<redacted>@192.168.10.1"), "Command output should preserve useful host context")
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
    try expect(webdavPlan.executable == "/usr/bin/osascript", "WebDAV mount should use AppleScript")
    try expect(webdavPlan.standardInput?.contains("https://dav.example.com/remote.php/dav/files/mei") == true, "WebDAV mount script missing URL")

    let webdavRoot = VolumeConfig(name: "RootDAV", protocolType: .webdav, server: "https://dav.example.com/base", remotePath: "/", username: "mei", mountPoint: "/Volumes/RootDAV", checkIntervalSeconds: 60, isEnabled: true)
    let webdavRootPlan = try MountPlanner().mountPlan(for: webdavRoot, password: "secret")
    try expect(webdavRootPlan.standardInput?.contains("https://dav.example.com/base") == true, "WebDAV / should mount the server/base root without an extra path level")
    let quietWebDAVPlan = try MountPlanner().mountPlan(for: webdavRoot, password: "secret", suppressesUserInterface: true)
    try expect(quietWebDAVPlan.executable == "/usr/bin/osascript", "WebDAV quiet mount should use AppleScript because mount_webdav rejects userinfo URLs")
    try expect(quietWebDAVPlan.standardInput?.contains("https://dav.example.com/base") == true, "WebDAV quiet mount script missing URL")
    try expect(quietWebDAVPlan.standardInput?.contains("mei") == true, "WebDAV quiet mount script missing username")
    try expect(quietWebDAVPlan.standardInput?.contains("secret") == true, "WebDAV quiet mount script missing password")

    let unmountPlan = MountPlanner().unmountPlan(mountPoint: "/Volumes/Team")
    try expect(unmountPlan == CommandPlan(executable: "/usr/sbin/diskutil", arguments: ["unmount", "/Volumes/Team"]), "Unmount plan mismatch")
    let forceUnmountPlan = MountPlanner().forceUnmountPlan(mountPoint: "/Volumes/Team")
    try expect(forceUnmountPlan == CommandPlan(executable: "/sbin/umount", arguments: ["-f", "/Volumes/Team"]), "Force unmount plan mismatch")
}

func testConnectivityPlanning() throws {
    let smb = VolumeConfig(name: "Team", protocolType: .smb, server: "smb://nas.local/team", remotePath: "team", username: "mei", mountPoint: "/Volumes/Team", checkIntervalSeconds: 60, isEnabled: true)
    let smbPlan = try ConnectivityTester().testPlan(for: smb, password: "secret")
    try expect(smbPlan == CommandPlan(executable: "/usr/bin/nc", arguments: ["-z", "-G", "5", "nas.local", "445"]), "SMB connectivity plan mismatch")

    let webdav = VolumeConfig(name: "DAV", protocolType: .webdav, server: "https://dav.example.com", remotePath: "remote.php/dav/files/mei", username: "mei", mountPoint: "/Volumes/DAV", checkIntervalSeconds: 60, isEnabled: true)
    let webdavPlan = try ConnectivityTester().testPlan(for: webdav, password: "secret")
    try expect(webdavPlan == CommandPlan(executable: "/usr/bin/curl", arguments: ["--user", "mei:secret", "--head", "--location", "--max-time", "10", "https://dav.example.com/remote.php/dav/files/mei"]), "WebDAV connectivity plan mismatch")

    let webdavBackslash = VolumeConfig(name: "DAVSlash", protocolType: .webdav, server: "https://dav.example.com/base", remotePath: "\\team\\video", username: nil, mountPoint: "/Volumes/DAVSlash", checkIntervalSeconds: 60, isEnabled: true)
    let webdavBackslashPlan = try ConnectivityTester().testPlan(for: webdavBackslash, password: nil)
    try expect(webdavBackslashPlan.arguments.last == "https://dav.example.com/base/team/video", "WebDAV connectivity should normalize backslashes")
}

func testMountExposureCreatesSubdirectoryLink() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }

    let config = VolumeConfig(
        id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
        name: "Tools",
        protocolType: .smb,
        server: "192.168.10.1",
        remotePath: "sda1/工具",
        username: "admin",
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
    //admin@192.168.10.1/sda1 on /Volumes/sda1 (smbfs, nodev, nosuid, mounted by xiaoan)
    https://mei@example.com/dav/files on /Volumes/DAV (webdav, nodev, nosuid, mounted by xiaoan)
    """
    let smb = VolumeConfig(name: "Router", protocolType: .smb, server: "192.168.10.1", remotePath: "", username: "admin", mountPoint: "/Users/xiaoan/Volumes/", checkIntervalSeconds: 240, isEnabled: true)
    let smbShare = VolumeConfig(name: "RouterShare", protocolType: .smb, server: "smb://192.168.10.1", remotePath: "sda1", username: "admin", mountPoint: "/Users/xiaoan/Volumes/", checkIntervalSeconds: 240, isEnabled: true)
    let webdav = VolumeConfig(name: "DAV", protocolType: .webdav, server: "https://example.com", remotePath: "dav/files", username: "mei", mountPoint: "/Volumes/DAV", checkIntervalSeconds: 240, isEnabled: true)
    let table = SystemMountTable(mountOutput: output)

    try expect(table.contains(config: smb), "Empty SMB remote path should match an existing server mount")
    try expect(table.contains(config: smbShare), "SMB remote share should match an existing share mount")
    try expect(table.contains(config: webdav), "WebDAV path should match an existing WebDAV mount")
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
    ("AgentEngine decisions", testAgentEngineDecisions),
    ("SystemMountTable", testSystemMountTableMatchesServerMounts),
    ("CheckScheduler", testCheckScheduler),
    ("AlertStore", testAlertStore)
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
