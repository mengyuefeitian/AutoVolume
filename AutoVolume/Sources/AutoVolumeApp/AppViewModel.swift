import Foundation
import Observation
import AutoVolumeShared

@Observable
public final class AppViewModel {
    public private(set) var volumes: [VolumeConfig] = []
    public var selectedVolumeID: VolumeConfig.ID?

    private let configStore: ConfigStore
    private let credentialStore: CredentialStore

    public init(configStore: ConfigStore = JSONConfigStore(), credentialStore: CredentialStore = KeychainCredentialStore()) {
        self.configStore = configStore
        self.credentialStore = credentialStore
        self.volumes = (try? configStore.load()) ?? []
    }

    public func add(_ config: VolumeConfig, password: String?) throws {
        volumes.append(config)
        try persist()
        if let password, !password.isEmpty {
            try credentialStore.savePassword(password, for: config.id)
        }
    }

    public func delete(_ config: VolumeConfig) throws {
        volumes.removeAll { $0.id == config.id }
        try persist()
        try credentialStore.deletePassword(for: config.id)
    }

    private func persist() throws {
        try configStore.save(volumes)
    }
}
