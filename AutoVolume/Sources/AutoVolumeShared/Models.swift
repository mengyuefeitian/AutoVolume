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
    public var smbOptions: SMBOptions

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case protocolType
        case server
        case remotePath
        case username
        case mountPoint
        case checkIntervalSeconds
        case isEnabled
        case smbOptions
    }

    public init(
        id: UUID = UUID(),
        name: String,
        protocolType: VolumeProtocol,
        server: String,
        remotePath: String,
        username: String?,
        mountPoint: String,
        checkIntervalSeconds: TimeInterval,
        isEnabled: Bool,
        smbOptions: SMBOptions = SMBOptions()
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
        self.smbOptions = smbOptions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.protocolType = try container.decode(VolumeProtocol.self, forKey: .protocolType)
        self.server = try container.decode(String.self, forKey: .server)
        self.remotePath = try container.decode(String.self, forKey: .remotePath)
        self.username = try container.decodeIfPresent(String.self, forKey: .username)
        self.mountPoint = try container.decode(String.self, forKey: .mountPoint)
        self.checkIntervalSeconds = try container.decode(TimeInterval.self, forKey: .checkIntervalSeconds)
        self.isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        self.smbOptions = try container.decodeIfPresent(SMBOptions.self, forKey: .smbOptions) ?? SMBOptions()
    }
}

public struct SMBOptions: Codable, Equatable {
    public var dialect: SMBDialect
    public var isMultichannelEnabled: Bool
    public var asyncDirectoryQueryCount: Int

    public init(
        dialect: SMBDialect = .smb3,
        isMultichannelEnabled: Bool = true,
        asyncDirectoryQueryCount: Int = 10
    ) {
        self.dialect = dialect
        self.isMultichannelEnabled = isMultichannelEnabled
        self.asyncDirectoryQueryCount = asyncDirectoryQueryCount
    }
}

public enum SMBDialect: String, Codable, CaseIterable, Identifiable {
    case smb2
    case smb2LargeMTU
    case smb3

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .smb2: "SMB2"
        case .smb2LargeMTU: "SMB2 + Large MTU"
        case .smb3: "Auto (SMB2-SMB3)"
        }
    }

    public var protocolVersionMap: Int {
        switch self {
        case .smb2:
            2
        case .smb2LargeMTU, .smb3:
            6
        }
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
