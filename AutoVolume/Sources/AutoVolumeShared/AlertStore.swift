import Foundation

public struct VolumeAlert: Codable, Identifiable, Equatable {
    public var id: UUID { volumeID }
    public var volumeID: UUID
    public var volumeName: String
    /// The English rendering of the alert, always present. Kept for logs, diagnostics, and as
    /// the fallback display text when `messageKey` is absent (alerts recorded before this
    /// field existed, or from a free-form/non-keyed source like raw command output).
    public var message: String
    public var date: Date
    /// The `L10nKey.rawValue` this alert was recorded with, if any. `String` (not `L10nKey`)
    /// so the type stays trivially `Codable`. Optional properties decode via `decodeIfPresent`
    /// automatically, so alerts persisted before this field existed decode with `nil` here.
    public var messageKey: String?
    public var messageArgs: [String]?

    public init(volumeID: UUID, volumeName: String, message: String, date: Date, messageKey: String? = nil, messageArgs: [String]? = nil) {
        self.volumeID = volumeID
        self.volumeName = volumeName
        self.message = message
        self.date = date
        self.messageKey = messageKey
        self.messageArgs = messageArgs
    }

    /// The alert rendered in the app's *current* language, resolved at read time. This is what
    /// makes alerts recorded earlier (possibly in a different language, or before a language
    /// switch) still render correctly today. Falls back to the stored English `message` for
    /// alerts with no key.
    public var localizedMessage: String {
        // A key that no longer exists in the English table (e.g. this alert was recorded by a
        // newer app version, then the user downgraded) has nothing to resolve against — fall
        // back to the stored English `message` rather than let `L10n.t` return the raw,
        // user-visible dotted key string.
        guard let messageKey, L10n.table(.en)[messageKey] != nil else { return message }
        return L10n.t(L10nKey(rawValue: messageKey), args: messageArgs ?? [])
    }
}

public final class AlertStore {
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let baseDirectory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("AutoVolume", isDirectory: true)
        self.fileURL = baseDirectory.appendingPathComponent("alerts.json")
    }

    public func load() throws -> [VolumeAlert] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([VolumeAlert].self, from: data)
    }

    public func record(volumeID: UUID, volumeName: String, message: String, date: Date = Date()) throws {
        try append(VolumeAlert(volumeID: volumeID, volumeName: volumeName, message: message, date: date))
    }

    /// Records a keyed alert. `message` is always stored as the English rendering (used for
    /// logs/diagnostics and as the fallback if the key is ever unrecognized); the current
    /// display language is resolved later, at read time, via `VolumeAlert.localizedMessage`.
    public func record(volumeID: UUID, volumeName: String, key: L10nKey, args: [String] = [], date: Date = Date()) throws {
        try append(VolumeAlert(
            volumeID: volumeID,
            volumeName: volumeName,
            message: L10n.t(key, args: args, in: .en),
            date: date,
            messageKey: key.rawValue,
            messageArgs: args
        ))
    }

    private func append(_ alert: VolumeAlert) throws {
        var alerts = try load()
        alerts.removeAll { $0.volumeID == alert.volumeID }
        alerts.append(alert)
        try save(alerts)
    }

    public func resolve(volumeID: UUID) throws {
        var alerts = try load()
        alerts.removeAll { $0.volumeID == volumeID }
        try save(alerts)
    }

    public func clear() throws {
        try save([])
    }

    private func save(_ alerts: [VolumeAlert]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(alerts).write(to: fileURL, options: .atomic)
    }
}
