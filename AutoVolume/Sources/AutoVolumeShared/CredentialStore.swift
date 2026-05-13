import Foundation
import CryptoKit
import Security

public protocol CredentialStore {
    func password(for volumeID: UUID) throws -> String?
    func savePassword(_ password: String, for volumeID: UUID) throws
    func deletePassword(for volumeID: UUID) throws
}

public enum CredentialStoreError: Error, Equatable {
    case invalidPasswordData
    case encryptionFailed
    case randomGenerationFailed
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

public final class EncryptedFileCredentialStore: CredentialStore {
    private struct Database: Codable {
        var version: Int
        var records: [String: EncryptedRecord]
    }

    private struct EncryptedRecord: Codable {
        var salt: String
        var nonce: String
        var ciphertext: String
        var tag: String
    }

    private let directory: URL
    private let databaseURL: URL
    private let secretURL: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("AutoVolume", isDirectory: true)
        self.databaseURL = self.directory.appendingPathComponent("credentials.db")
        self.secretURL = self.directory.appendingPathComponent("credentials.secret")
    }

    public func password(for volumeID: UUID) throws -> String? {
        let database = try loadDatabase()
        guard let record = database.records[volumeID.uuidString] else { return nil }
        guard let salt = Data(base64Encoded: record.salt),
              let nonceData = Data(base64Encoded: record.nonce),
              let ciphertext = Data(base64Encoded: record.ciphertext),
              let tag = Data(base64Encoded: record.tag),
              let nonce = try? AES.GCM.Nonce(data: nonceData) else {
            throw CredentialStoreError.invalidPasswordData
        }
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let decryptedData = try AES.GCM.open(sealedBox, using: key(for: salt))
        guard let password = String(data: decryptedData, encoding: .utf8) else {
            throw CredentialStoreError.invalidPasswordData
        }
        return password
    }

    public func savePassword(_ password: String, for volumeID: UUID) throws {
        var database = try loadDatabase()
        let salt = try randomData(count: 32)
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(Data(password.utf8), using: key(for: salt), nonce: nonce)
        database.records[volumeID.uuidString] = EncryptedRecord(
            salt: salt.base64EncodedString(),
            nonce: Data(nonce).base64EncodedString(),
            ciphertext: sealedBox.ciphertext.base64EncodedString(),
            tag: sealedBox.tag.base64EncodedString()
        )
        try save(database)
    }

    public func deletePassword(for volumeID: UUID) throws {
        var database = try loadDatabase()
        database.records.removeValue(forKey: volumeID.uuidString)
        try save(database)
    }

    private func loadDatabase() throws -> Database {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return Database(version: 1, records: [:])
        }
        let data = try Data(contentsOf: databaseURL)
        return try JSONDecoder().decode(Database.self, from: data)
    }

    private func save(_ database: Database) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(database).write(to: databaseURL, options: .atomic)
        try restrictOwnerAccess(to: databaseURL)
    }

    private func key(for salt: Data) throws -> SymmetricKey {
        var keyMaterial = Data()
        keyMaterial.append(try localSecret())
        keyMaterial.append(salt)
        return SymmetricKey(data: Data(SHA256.hash(data: keyMaterial)))
    }

    private func localSecret() throws -> Data {
        if FileManager.default.fileExists(atPath: secretURL.path) {
            return try Data(contentsOf: secretURL)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let secret = try randomData(count: 32)
        try secret.write(to: secretURL, options: .atomic)
        try restrictOwnerAccess(to: secretURL)
        return secret
    }

    private func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw CredentialStoreError.randomGenerationFailed }
        return data
    }

    private func restrictOwnerAccess(to url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
