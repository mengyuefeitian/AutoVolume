import Foundation

public struct MountExposure {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func prepare(config: VolumeConfig, planner: MountPlanner) throws {
        let effectiveMountPoint = planner.effectiveMountPoint(for: config)
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: effectiveMountPoint),
            withIntermediateDirectories: true
        )
    }

    public func expose(config: VolumeConfig, planner: MountPlanner) throws {
        guard let targetPath = planner.exposedPathTarget(for: config) else { return }
        let linkURL = URL(fileURLWithPath: config.mountPoint)
        try fileManager.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try replaceExistingLinkOrEmptyDirectory(at: linkURL)
        try fileManager.createSymbolicLink(atPath: linkURL.path, withDestinationPath: targetPath)
    }

    private func replaceExistingLinkOrEmptyDirectory(at url: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }

        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
            try fileManager.removeItem(at: url)
            return
        }

        if isDirectory.boolValue {
            let contents = try fileManager.contentsOfDirectory(atPath: url.path)
            if contents.isEmpty {
                try fileManager.removeItem(at: url)
            }
        }
    }
}
