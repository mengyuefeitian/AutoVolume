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

func testMountPlanning() throws {
    let smb = VolumeConfig(name: "Team", protocolType: .smb, server: "nas.local", remotePath: "team", username: "mei", mountPoint: "/Volumes/Team", checkIntervalSeconds: 60, isEnabled: true)
    let smbPlan = try MountPlanner().mountPlan(for: smb, password: "secret")
    try expect(smbPlan.executable == "/usr/bin/osascript", "SMB mount should use AppleScript")
    try expect(smbPlan.arguments == ["-"], "SMB mount should pass AppleScript through stdin")
    try expect(smbPlan.standardInput?.contains("smb://nas.local/team") == true, "SMB mount script missing URL")

    let smbNested = VolumeConfig(name: "Video", protocolType: .smb, server: "smb://nas.local/ignored", remotePath: "/video/projects", username: "mei", mountPoint: "/Volumes/Video", checkIntervalSeconds: 60, isEnabled: true)
    let smbNestedPlan = try MountPlanner().mountPlan(for: smbNested, password: "secret")
    try expect(smbNestedPlan.standardInput?.contains("smb://nas.local/video/projects") == true, "SMB mount should normalize host and remote subpath")

    let nfs = VolumeConfig(name: "Exports", protocolType: .nfs, server: "nas.local", remotePath: "/exports/team", username: nil, mountPoint: "/Volumes/Exports", checkIntervalSeconds: 60, isEnabled: true)
    let nfsPlan = try MountPlanner().mountPlan(for: nfs, password: nil)
    try expect(nfsPlan == CommandPlan(executable: "/sbin/mount_nfs", arguments: ["nas.local:/exports/team", "/Volumes/Exports"]), "NFS mount plan mismatch")

    let webdav = VolumeConfig(name: "DAV", protocolType: .webdav, server: "dav.example.com", remotePath: "remote.php/dav/files/mei", username: "mei", mountPoint: "/Volumes/DAV", checkIntervalSeconds: 60, isEnabled: true)
    let webdavPlan = try MountPlanner().mountPlan(for: webdav, password: "secret")
    try expect(webdavPlan.executable == "/usr/bin/osascript", "WebDAV mount should use AppleScript")
    try expect(webdavPlan.standardInput?.contains("https://dav.example.com/remote.php/dav/files/mei") == true, "WebDAV mount script missing URL")

    let webdavRoot = VolumeConfig(name: "RootDAV", protocolType: .webdav, server: "https://dav.example.com/base", remotePath: "/", username: "mei", mountPoint: "/Volumes/RootDAV", checkIntervalSeconds: 60, isEnabled: true)
    let webdavRootPlan = try MountPlanner().mountPlan(for: webdavRoot, password: "secret")
    try expect(webdavRootPlan.standardInput?.contains("https://dav.example.com/base") == true, "WebDAV / should mount the server/base root without an extra path level")

    let unmountPlan = MountPlanner().unmountPlan(mountPoint: "/Volumes/Team")
    try expect(unmountPlan == CommandPlan(executable: "/usr/sbin/diskutil", arguments: ["unmount", "/Volumes/Team"]), "Unmount plan mismatch")
}

func testConnectivityPlanning() throws {
    let smb = VolumeConfig(name: "Team", protocolType: .smb, server: "smb://nas.local/team", remotePath: "team", username: "mei", mountPoint: "/Volumes/Team", checkIntervalSeconds: 60, isEnabled: true)
    let smbPlan = try ConnectivityTester().testPlan(for: smb, password: "secret")
    try expect(smbPlan == CommandPlan(executable: "/usr/bin/nc", arguments: ["-z", "-G", "5", "nas.local", "445"]), "SMB connectivity plan mismatch")

    let webdav = VolumeConfig(name: "DAV", protocolType: .webdav, server: "https://dav.example.com", remotePath: "remote.php/dav/files/mei", username: "mei", mountPoint: "/Volumes/DAV", checkIntervalSeconds: 60, isEnabled: true)
    let webdavPlan = try ConnectivityTester().testPlan(for: webdav, password: "secret")
    try expect(webdavPlan == CommandPlan(executable: "/usr/bin/curl", arguments: ["--user", "mei:secret", "--head", "--location", "--max-time", "10", "https://dav.example.com/remote.php/dav/files/mei"]), "WebDAV connectivity plan mismatch")
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
    try expect(unmountedRunner.plans.first?.executable == "/usr/bin/osascript", "Unmounted volume should use macOS mount volume")
}

func testCheckScheduler() throws {
    let id = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    var scheduler = CheckScheduler()

    try expect(scheduler.isDue(volumeID: id, interval: 300, now: Date(timeIntervalSince1970: 1_000)), "Unseen volume should be due")
    scheduler.markChecked(volumeID: id, at: Date(timeIntervalSince1970: 1_000))
    try expect(!scheduler.isDue(volumeID: id, interval: 300, now: Date(timeIntervalSince1970: 1_299)), "Volume should not be due before interval")
    try expect(scheduler.isDue(volumeID: id, interval: 300, now: Date(timeIntervalSince1970: 1_300)), "Volume should be due after interval")
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

let tests: [(String, () throws -> Void)] = [
    ("VolumeConfig JSON round trip", testVolumeConfigRoundTripsThroughJSON),
    ("ConfigStore save/load", testConfigStoreSaveLoadAndMissingFile),
    ("InMemoryCredentialStore", testInMemoryCredentialStore),
    ("MountPlanning", testMountPlanning),
    ("ConnectivityPlanning", testConnectivityPlanning),
    ("AgentEngine decisions", testAgentEngineDecisions),
    ("CheckScheduler", testCheckScheduler)
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
