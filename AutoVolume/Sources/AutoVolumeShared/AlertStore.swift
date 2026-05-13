import Foundation

public struct VolumeAlert: Codable, Identifiable, Equatable {
    public var id: UUID { volumeID }
    public var volumeID: UUID
    public var volumeName: String
    public var message: String
    public var date: Date

    public init(volumeID: UUID, volumeName: String, message: String, date: Date) {
        self.volumeID = volumeID
        self.volumeName = volumeName
        self.message = message
        self.date = date
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
        var alerts = try load()
        alerts.removeAll { $0.volumeID == volumeID }
        alerts.append(VolumeAlert(volumeID: volumeID, volumeName: volumeName, message: message, date: date))
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
