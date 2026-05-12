import XCTest
@testable import AutoVolumeShared

final class AgentEngineTests: XCTestCase {
    func testDisabledVolumeIsSkipped() throws {
        let config = VolumeConfig(name: "Off", protocolType: .smb, server: "nas.local", remotePath: "off", username: nil, mountPoint: "/Volumes/Off", checkIntervalSeconds: 60, isEnabled: false)
        let engine = AgentEngine(mountState: FakeMountStateProvider(isMounted: false), credentialStore: InMemoryCredentialStore(), commandRunner: RecordingCommandRunner(), mountPlanner: MountPlanner())

        let status = try engine.check(config)

        XCTAssertEqual(status, .unmounted)
    }

    func testMountedVolumeStaysMountedWithoutCommand() throws {
        let config = VolumeConfig(name: "Team", protocolType: .smb, server: "nas.local", remotePath: "team", username: nil, mountPoint: "/Volumes/Team", checkIntervalSeconds: 60, isEnabled: true)
        let runner = RecordingCommandRunner()
        let engine = AgentEngine(mountState: FakeMountStateProvider(isMounted: true), credentialStore: InMemoryCredentialStore(), commandRunner: runner, mountPlanner: MountPlanner())

        let status = try engine.check(config)

        XCTAssertEqual(status, .mounted)
        XCTAssertEqual(runner.plans, [])
    }

    func testUnmountedVolumeRunsMountCommand() throws {
        let id = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let config = VolumeConfig(id: id, name: "Team", protocolType: .smb, server: "nas.local", remotePath: "team", username: "mei", mountPoint: "/Volumes/Team", checkIntervalSeconds: 60, isEnabled: true)
        let credentials = InMemoryCredentialStore()
        try credentials.savePassword("secret", for: id)
        let runner = RecordingCommandRunner(result: CommandResult(exitCode: 0, stdout: "", stderr: ""))
        let engine = AgentEngine(mountState: FakeMountStateProvider(isMounted: false), credentialStore: credentials, commandRunner: runner, mountPlanner: MountPlanner())

        let status = try engine.check(config)

        XCTAssertEqual(status, .mounted)
        XCTAssertEqual(runner.plans.first?.executable, "/usr/bin/open")
    }
}

private struct FakeMountStateProvider: MountStateProvider {
    let isMounted: Bool
    func isMounted(config: VolumeConfig) -> Bool { isMounted }
}

private final class RecordingCommandRunner: CommandRunner {
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
