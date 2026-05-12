import XCTest
@testable import AutoVolumeShared

final class ConfigStoreTests: XCTestCase {
    func testSaveAndLoadVolumes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = JSONConfigStore(directory: directory)
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
        let loaded = try store.load()

        XCTAssertEqual(loaded, [volume])
    }

    func testLoadReturnsEmptyArrayWhenConfigDoesNotExist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = JSONConfigStore(directory: directory)

        XCTAssertEqual(try store.load(), [])
    }
}
