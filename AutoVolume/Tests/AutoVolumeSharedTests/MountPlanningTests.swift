import XCTest
@testable import AutoVolumeShared

final class MountPlanningTests: XCTestCase {
    func testSMBPlanUsesOpenWithSMBURL() throws {
        let config = VolumeConfig(name: "Team", protocolType: .smb, server: "nas.local", remotePath: "team", username: "mei", mountPoint: "/Volumes/Team", checkIntervalSeconds: 60, isEnabled: true)

        let plan = try MountPlanner().mountPlan(for: config, password: "secret")

        XCTAssertEqual(plan.executable, "/usr/bin/open")
        XCTAssertEqual(plan.arguments, ["smb://mei@nas.local/team"])
    }

    func testNFSPlanUsesMountNFS() throws {
        let config = VolumeConfig(name: "Exports", protocolType: .nfs, server: "nas.local", remotePath: "/exports/team", username: nil, mountPoint: "/Volumes/Exports", checkIntervalSeconds: 60, isEnabled: true)

        let plan = try MountPlanner().mountPlan(for: config, password: nil)

        XCTAssertEqual(plan.executable, "/sbin/mount_nfs")
        XCTAssertEqual(plan.arguments, ["nas.local:/exports/team", "/Volumes/Exports"])
    }

    func testUnmountPlanUsesDiskutil() {
        let plan = MountPlanner().unmountPlan(mountPoint: "/Volumes/Team")

        XCTAssertEqual(plan.executable, "/usr/sbin/diskutil")
        XCTAssertEqual(plan.arguments, ["unmount", "/Volumes/Team"])
    }
}
