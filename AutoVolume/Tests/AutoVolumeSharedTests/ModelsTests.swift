import XCTest
@testable import AutoVolumeShared

final class ModelsTests: XCTestCase {
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

        XCTAssertEqual(decoded, config)
    }
}
