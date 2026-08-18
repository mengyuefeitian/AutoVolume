import Foundation

public enum LogLevel: Int, Codable, CaseIterable, Comparable {
    case info = 0
    case warning = 1
    case error = 2

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct AppSettings: Codable, Equatable {
    public var logLevel: LogLevel
    public var openFinderAfterMount: Bool

    public init(logLevel: LogLevel = .info, openFinderAfterMount: Bool = true) {
        self.logLevel = logLevel
        self.openFinderAfterMount = openFinderAfterMount
    }
}

public protocol AppSettingsStore {
    func load() throws -> AppSettings
    func save(_ settings: AppSettings) throws
}

public final class JSONAppSettingsStore: AppSettingsStore {
    private let directory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL = JSONAppSettingsStore.defaultDirectory, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AutoVolume", isDirectory: true)
    }

    public var fileURL: URL {
        directory.appendingPathComponent("settings.json")
    }

    public func load() throws -> AppSettings {
        guard fileManager.fileExists(atPath: fileURL.path) else { return AppSettings() }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(AppSettings.self, from: data)
    }

    public func save(_ settings: AppSettings) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: [.atomic])
    }
}
