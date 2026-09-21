import Foundation

public struct NTFSVolume: Codable, Identifiable, Equatable {
    public var id: String { bsdName }
    public var bsdName: String
    public var volumeName: String
    public var devicePath: String
    public var mountPoint: String
    public var mountedAt: Date

    public init(bsdName: String, volumeName: String, devicePath: String, mountPoint: String, mountedAt: Date) {
        self.bsdName = bsdName
        self.volumeName = volumeName
        self.devicePath = devicePath
        self.mountPoint = mountPoint
        self.mountedAt = mountedAt
    }
}

public enum NTFSDiskClassifier {
    public static func isNTFSFileSystem(personality: String?) -> Bool {
        guard let personality else { return false }
        return personality.lowercased().contains("ntfs")
    }

    public static func isOwnedByOurDriver(mountedFileSystemName: String?) -> Bool {
        guard let mountedFileSystemName else { return false }
        return mountedFileSystemName.lowercased().contains("fusefs_ntfs")
    }
}
