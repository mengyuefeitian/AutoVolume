import Foundation

public final class NTFSMountedVolumesStore {
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let baseDirectory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("AutoVolume", isDirectory: true)
        self.fileURL = baseDirectory.appendingPathComponent("ntfs-volumes.json")
    }

    public func load() throws -> [NTFSVolume] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([NTFSVolume].self, from: data)
    }

    public func add(_ volume: NTFSVolume) throws {
        var volumes = try load()
        volumes.removeAll { $0.bsdName == volume.bsdName }
        volumes.append(volume)
        try save(volumes)
    }

    public func remove(bsdName: String) throws {
        var volumes = try load()
        volumes.removeAll { $0.bsdName == bsdName }
        try save(volumes)
    }

    private func save(_ volumes: [NTFSVolume]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(volumes).write(to: fileURL, options: .atomic)
    }
}
