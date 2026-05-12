import Foundation

public enum VolumeProtocol: String, Codable, CaseIterable, Identifiable {
    case smb
    case webdav
    case afp
    case nfs

    public var id: String { rawValue }
}

public struct VolumeConfig: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var protocolType: VolumeProtocol
    public var server: String
    public var remotePath: String
    public var username: String?
    public var mountPoint: String
    public var checkIntervalSeconds: TimeInterval
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        protocolType: VolumeProtocol,
        server: String,
        remotePath: String,
        username: String?,
        mountPoint: String,
        checkIntervalSeconds: TimeInterval,
        isEnabled: Bool
    ) {
        self.id = id
        self.name = name
        self.protocolType = protocolType
        self.server = server
        self.remotePath = remotePath
        self.username = username
        self.mountPoint = mountPoint
        self.checkIntervalSeconds = checkIntervalSeconds
        self.isEnabled = isEnabled
    }
}

public enum VolumeStatus: Codable, Equatable {
    case mounted
    case unmounted
    case checking
    case failed(message: String)
}

public enum MountErrorCategory: String, Codable, Equatable {
    case authenticationFailed
    case networkUnavailable
    case invalidMountPoint
    case commandFailed
    case unknown
}
