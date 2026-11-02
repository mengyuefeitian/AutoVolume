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
    public var nfsOptions: NFSOptions

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
        case nfsOptions
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
        smbOptions: SMBOptions = SMBOptions(),
        nfsOptions: NFSOptions = NFSOptions()
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
        self.nfsOptions = nfsOptions
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
        self.nfsOptions = try container.decodeIfPresent(NFSOptions.self, forKey: .nfsOptions) ?? NFSOptions()
    }
}

/// How an NFS volume is kept mounted.
///
/// `hard` is the right choice for a share that stays mounted for days: when the network or the NAS
/// disappears, the kernel keeps retrying and carries on when it returns, with the mount intact. `soft`
/// gives up after a timeout and leaves a dead mount that only a forced unmount clears — usable for a
/// quick job, wrong for a library that is scanned around the clock. The cost of `hard` is that anything
/// touching the mount blocks while the server is away (Finder beachballs); `intr` lets a stuck process be
/// killed, which the agent's own probes rely on.
public enum NFSMountMode: String, Codable, CaseIterable, Identifiable {
    case hard
    case soft

    public var id: String { rawValue }
}

/// NFS protocol version. v3 is the default: it is what these NAS boxes were verified with, it is
/// deterministic, and unlike letting macOS choose it never silently falls back to v2. v4.1 is offered for
/// servers set up for it; it needs the NAS side configured too, which this app cannot check.
public enum NFSVersion: String, Codable, CaseIterable, Identifiable {
    case v3
    case v4_1
    case auto

    public var id: String { rawValue }
}

public struct NFSOptions: Codable, Equatable {
    public var mode: NFSMountMode
    public var version: NFSVersion

    public init(mode: NFSMountMode = .hard, version: NFSVersion = .v3) {
        self.mode = mode
        self.version = version
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
        case .smb3: L10n.t(.editorSmbDialectAuto)
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
    /// `key`/`args` carry the `L10nKey.rawValue` and substitution args for failures that came
    /// from a fixed, keyed sentence (`String`, not `L10nKey`, so this stays trivially
    /// `Codable`). Both default so existing `.failed(message:)` call sites compile unchanged;
    /// `key == nil` for failures built from raw command/error output, which has no key to
    /// localize.
    case failed(message: String, key: String? = nil, args: [String] = [])
}

public enum MountErrorCategory: String, Codable, Equatable {
    case authenticationFailed
    case networkUnavailable
    case invalidMountPoint
    case commandFailed
    case unknown
}
