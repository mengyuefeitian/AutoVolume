import Foundation

public protocol MountStateProvider {
    func isMounted(config: VolumeConfig) -> Bool
}

public final class FileSystemMountStateProvider: MountStateProvider {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func isMounted(config: VolumeConfig) -> Bool {
        let mountURL = URL(fileURLWithPath: config.mountPoint)
        guard fileManager.fileExists(atPath: mountURL.path) else { return false }
        guard let mountedURLs = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) else {
            return false
        }
        return mountedURLs.contains { $0.standardizedFileURL.path == mountURL.standardizedFileURL.path }
    }
}
