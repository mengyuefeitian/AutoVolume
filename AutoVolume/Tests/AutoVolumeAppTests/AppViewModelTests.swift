import XCTest
@testable import AutoVolumeApp
@testable import AutoVolumeShared

final class AppViewModelTests: XCTestCase {
    func testAddVolumePersistsConfigAndPassword() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let configStore = JSONConfigStore(directory: directory)
        let credentialStore = InMemoryCredentialStore()
        let viewModel = AppViewModel(configStore: configStore, credentialStore: credentialStore)
        let config = VolumeConfig(name: "Media", protocolType: .webdav, server: "dav.example.com", remotePath: "media", username: "mei", mountPoint: "/Volumes/Media", checkIntervalSeconds: 300, isEnabled: true)

        try viewModel.add(config, password: "secret")

        XCTAssertEqual(try configStore.load(), [config])
        XCTAssertEqual(try credentialStore.password(for: config.id), "secret")
    }

    func testUpdateSettingsPersistsToSettingsStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let settingsStore = JSONAppSettingsStore(directory: directory)
        let viewModel = AppViewModel(credentialStore: InMemoryCredentialStore(), settingsStore: settingsStore)

        viewModel.updateSettings(AppSettings(logLevel: .error, openFinderAfterMount: false))

        XCTAssertEqual(viewModel.settings, AppSettings(logLevel: .error, openFinderAfterMount: false))
        XCTAssertEqual(try settingsStore.load(), AppSettings(logLevel: .error, openFinderAfterMount: false))
    }
}
