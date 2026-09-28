import Foundation

public enum NTFSDriverPaths {
    public static let installDirectory = "/Library/PrivilegedHelperTools/com.autovolume.ntfsdriver"
    public static var ntfs3gExecutablePath: String { installDirectory + "/ntfs-3g" }
    public static var ntfs3gDylibPath: String { installDirectory + "/libntfs-3g.89.dylib" }
    /// `NTFSPrivilegedHelper` links against `AutoVolumeShared`; since it runs standalone
    /// as a LaunchDaemon (not from inside the app bundle), a copy of the shared dylib is
    /// installed alongside the driver so its rpath can resolve it at load time.
    public static var sharedLibraryPath: String { installDirectory + "/libAutoVolumeShared.dylib" }
    /// Stamped with the app bundle's `CFBundleVersion` after each successful install, so a
    /// Sparkle update that replaces `/Applications/AutoVolume.app` (but not this root-owned
    /// directory) can be detected and trigger a reinstall.
    public static var versionStampPath: String { installDirectory + "/installed-build" }
}

public enum NTFSHelperSocket {
    public static let path = "/var/run/com.autovolume.ntfshelper.sock"
    public static let daemonLabel = "com.autovolume.ntfshelper"
    public static let daemonPlistInstallPath = "/Library/LaunchDaemons/com.autovolume.ntfshelper.plist"
    public static let helperInstallPath = "/Library/PrivilegedHelperTools/com.autovolume.ntfshelper"
    /// newsyslog.d rotates the helper's StandardOutPath/StandardErrorPath log so it
    /// doesn't grow unbounded (flagged in Task 7's security review).
    public static let newsyslogConfInstallPath = "/etc/newsyslog.d/com.autovolume.ntfshelper.conf"
}

public enum NTFSHelperAction: String, Codable, Equatable {
    case mount
    case unmount
    /// Probes whether this daemon's process has Full Disk Access, independent of any
    /// particular volume — see `checkFullDiskAccess()` in `NTFSPrivilegedHelper/main.swift`.
    case checkFullDiskAccess
}

public struct NTFSHelperRequest: Codable, Equatable {
    public var action: NTFSHelperAction
    public var devicePath: String?
    public var mountPoint: String
    /// The volume's own name (from DiskArbitration), passed through so the helper can pass
    /// `-o volname=` to ntfs-3g. Without it, ntfs-3g/FUSE-T falls back to naming the mount
    /// after the mount point's last path component — which happens to match the volume name
    /// today only because that's what DiskArbitration used to choose the mount point in the
    /// first place, not because it's guaranteed to. `nil` for `.unmount` requests, which don't
    /// need it.
    public var volumeName: String?

    public init(action: NTFSHelperAction, devicePath: String? = nil, mountPoint: String, volumeName: String? = nil) {
        self.action = action
        self.devicePath = devicePath
        self.mountPoint = mountPoint
        self.volumeName = volumeName
    }

    public static func checkFullDiskAccess() -> NTFSHelperRequest {
        NTFSHelperRequest(action: .checkFullDiskAccess, mountPoint: "")
    }
}

public struct NTFSHelperResponse: Codable, Equatable {
    public var success: Bool
    public var message: String
    /// Set when the helper had to retry the mount with `-o remove_hiberfile` because the first
    /// attempt failed with ntfs-3g's documented hibernation exit code (see
    /// `NTFSMountFailureClassifier`). Lets `NTFSAutoMountService` surface a one-time,
    /// user-facing notice explaining why a hibernation state was cleared automatically, instead
    /// of silently discarding Windows session state with no record of it.
    public var recoveredFromHibernation: Bool

    public init(success: Bool, message: String = "", recoveredFromHibernation: Bool = false) {
        self.success = success
        self.message = message
        self.recoveredFromHibernation = recoveredFromHibernation
    }
}

public enum NTFSHelperWireFormat {
    public static func encode(_ request: NTFSHelperRequest) throws -> Data {
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        return data
    }

    public static func encode(_ response: NTFSHelperResponse) throws -> Data {
        var data = try JSONEncoder().encode(response)
        data.append(0x0A)
        return data
    }

    public static func decodeRequest(_ data: Data) throws -> NTFSHelperRequest {
        try JSONDecoder().decode(NTFSHelperRequest.self, from: trimmedTrailingNewline(data))
    }

    public static func decodeResponse(_ data: Data) throws -> NTFSHelperResponse {
        try JSONDecoder().decode(NTFSHelperResponse.self, from: trimmedTrailingNewline(data))
    }

    private static func trimmedTrailingNewline(_ data: Data) -> Data {
        guard data.last == 0x0A else { return data }
        return data.dropLast()
    }
}

public enum NTFSHelperRequestValidator {
    public static func validate(_ request: NTFSHelperRequest) -> String? {
        // Has no mountPoint of its own — it probes a fixed device, not anything under /Volumes.
        guard request.action != .checkFullDiskAccess else { return nil }
        guard request.mountPoint.hasPrefix("/Volumes/") else {
            return "mountPoint must be under /Volumes"
        }
        if request.action == .mount, request.devicePath == nil {
            return "devicePath is required for mount"
        }
        return nil
    }
}
