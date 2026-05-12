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
        return password
    }

    public func savePassword(_ password: String, for volumeID: UUID) throws {
        try deletePassword(for: volumeID)
        var item = baseQuery(for: volumeID)
        item[kSecValueData as String] = Data(password.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialStoreError.keychainFailure(status) }
    }

    public func deletePassword(for volumeID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: volumeID) as CFDictionary)
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
}
