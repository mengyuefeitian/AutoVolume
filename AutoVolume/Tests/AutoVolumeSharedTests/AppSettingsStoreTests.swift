import XCTest
@testable import AutoVolumeShared

final class AppSettingsStoreTests: XCTestCase {
    func testLoadReturnsDefaultsWhenSettingsFileDoesNotExist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JSONAppSettingsStore(directory: directory)

        let settings = try store.load()

        XCTAssertEqual(settings.logLevel, .info)
        XCTAssertEqual(settings.openFinderAfterMount, true)
    }

    func testSaveAndLoadRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JSONAppSettingsStore(directory: directory)
        let settings = AppSettings(logLevel: .error, openFinderAfterMount: false)

        try store.save(settings)
        let loaded = try store.load()

        XCTAssertEqual(loaded, settings)
    }
}
