import Foundation

public protocol ConfigStore {
    func load() throws -> [VolumeConfig]
    func save(_ configs: [VolumeConfig]) throws
}

public final class JSONConfigStore: ConfigStore {
    private let directory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL = JSONConfigStore.defaultDirectory, fileManager: FileManager = .default) {
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
        directory.appendingPathComponent("volumes.json")
    }

    public func load() throws -> [VolumeConfig] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([VolumeConfig].self, from: data)
    }

    public func save(_ configs: [VolumeConfig]) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(configs)
        try data.write(to: fileURL, options: [.atomic])
    }
}
