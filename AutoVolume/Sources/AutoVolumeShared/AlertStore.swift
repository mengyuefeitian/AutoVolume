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

/// `NTFSAutoMountService` (running on the Agent's `ntfsDiskQueue`) and the Agent's regular
/// SMB/WebDAV check cycle (running on main) both construct their own `AlertStore` pointed at the
/// same default `alerts.json` — different instances of this class, same file. Before NTFS
/// handling moved off the main run loop, every call into either instance was still serialized in
/// time because only one thread ever ran Swift code at once; now they can genuinely run
/// concurrently, and a `load()` → mutate → `save()` cycle from one thread interleaving with
/// another's would silently lose whichever alert was written first (`.atomic` only prevents a
/// torn/corrupt file, not this kind of lost update). The lock below makes every public operation
/// on a given `AlertStore` instance mutually exclusive; combined with both instances resolving to
/// the same file, that's sufficient because file writes are already atomic — the last writer
/// under the lock always sees the immediately-prior writer's result, whichever instance it went
/// through.
public final class AlertStore {
    private let fileURL: URL
    private let lock = NSLock()

    public init(directory: URL? = nil) {
        let baseDirectory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("AutoVolume", isDirectory: true)
        self.fileURL = baseDirectory.appendingPathComponent("alerts.json")
    }

    public func load() throws -> [VolumeAlert] {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()
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
        lock.lock()
        defer { lock.unlock() }
        var alerts = try loadLocked()
        alerts.removeAll { $0.volumeID == alert.volumeID }
        alerts.append(alert)
        try saveLocked(alerts)
    }

    public func resolve(volumeID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        var alerts = try loadLocked()
        alerts.removeAll { $0.volumeID == volumeID }
        try saveLocked(alerts)
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        try saveLocked([])
    }

    /// Callers must already hold `lock`.
    private func loadLocked() throws -> [VolumeAlert] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([VolumeAlert].self, from: data)
    }

    /// Callers must already hold `lock`.
    private func saveLocked(_ alerts: [VolumeAlert]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(alerts).write(to: fileURL, options: .atomic)
    }
}
