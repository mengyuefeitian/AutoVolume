import Foundation
import Security

public protocol CredentialStore {
    func password(for volumeID: UUID) throws -> String?
    func savePassword(_ password: String, for volumeID: UUID) throws
    func deletePassword(for volumeID: UUID) throws
}

public enum CredentialStoreError: Error, Equatable {
    case keychainFailure(OSStatus)
    case invalidPasswordData
}

public final class InMemoryCredentialStore: CredentialStore {
    private var values: [UUID: String] = [:]

    public init() {}

    public func password(for volumeID: UUID) throws -> String? {
        values[volumeID]
    }

    public func savePassword(_ password: String, for volumeID: UUID) throws {
        values[volumeID] = password
    }

    public func deletePassword(for volumeID: UUID) throws {
        values.removeValue(forKey: volumeID)
    }
}

public final class KeychainCredentialStore: CredentialStore {
    private let service = "com.autovolume.credentials"

    public init() {}

    public func password(for volumeID: UUID) throws -> String? {
        var query = baseQuery(for: volumeID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.keychainFailure(status) }
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.invalidPasswordData
        }
        try? refreshAccess(for: volumeID)
        return password
    }

    public func savePassword(_ password: String, for volumeID: UUID) throws {
        let passwordData = Data(password.utf8)
        var attributes: [String: Any] = [kSecValueData as String: passwordData]
        if let access = Self.keychainAccess() {
            attributes[kSecAttrAccess as String] = access
        }

        let updateStatus = SecItemUpdate(baseQuery(for: volumeID) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychainFailure(updateStatus)
        }

        var item = baseQuery(for: volumeID)
        item.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CredentialStoreError.keychainFailure(addStatus) }
    }

    public func deletePassword(for volumeID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: volumeID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainFailure(status)
        }
    }

    private func refreshAccess(for volumeID: UUID) throws {
        guard let access = Self.keychainAccess() else { return }
        let attributes = [kSecAttrAccess as String: access]
        let status = SecItemUpdate(baseQuery(for: volumeID) as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainFailure(status)
        }
    }

    private func baseQuery(for volumeID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: volumeID.uuidString
        ]
    }

    private static func keychainAccess() -> SecAccess? {
        let trustedApplications = trustedApplicationPaths().compactMap { path -> SecTrustedApplication? in
            var trustedApplication: SecTrustedApplication?
            let status = SecTrustedApplicationCreateFromPath(path, &trustedApplication)
            guard status == errSecSuccess else { return nil }
            return trustedApplication
        }

        guard !trustedApplications.isEmpty else { return nil }
        var access: SecAccess?
        let status = SecAccessCreate("AutoVolume network volume credentials" as CFString, trustedApplications as CFArray, &access)
        guard status == errSecSuccess else { return nil }
        return access
    }

    private static func trustedApplicationPaths() -> [String?] {
        var paths: [String?] = [nil]
        let mainBundle = Bundle.main
        let executablePath = mainBundle.executablePath ?? CommandLine.arguments.first
        if let executablePath {
            paths.append(executablePath)
        }
        if let bundledAgentPath = mainBundle.url(forResource: "AutoVolumeAgent", withExtension: nil)?.path {
            paths.append(bundledAgentPath)
        } else if let executablePath {
            let executableURL = URL(fileURLWithPath: executablePath)
            let bundledAgentURL = executableURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("AutoVolumeAgent")
            paths.append(bundledAgentURL.path)
        }
        return Array(Set(paths))
    }
}
