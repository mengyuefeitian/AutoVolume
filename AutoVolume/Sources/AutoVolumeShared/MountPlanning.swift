import Foundation

public enum MountPlanningError: Error, Equatable, LocalizedError {
    case invalidURL

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid remote path. SMB requires a share name, for example sda1 or video."
        }
    }
}

public struct MountPlanner {
    public init() {}

    public func mountPlan(for config: VolumeConfig, password: String?, suppressesUserInterface: Bool = false) throws -> CommandPlan {
        if suppressesUserInterface {
            return try quietMountPlan(for: config, password: password)
        }
        switch config.protocolType {
        case .smb:
            return try appleScriptMountPlan(url: urlString(scheme: "smb", config: config, includeUser: false), username: config.username, password: password)
        case .webdav:
            return try appleScriptMountPlan(url: webDAVURLString(config: config, includeUser: false), username: config.username, password: password)
        case .afp:
            return try appleScriptMountPlan(url: urlString(scheme: "afp", config: config, includeUser: false), username: config.username, password: password)
        case .nfs:
            return CommandPlan(executable: "/sbin/mount_nfs", arguments: ["\(hostOnly(config.server)):\(nfsRemotePath(config.remotePath))", config.mountPoint])
        }
    }

    public func effectiveMountPoint(for config: VolumeConfig) -> String {
        guard let smbPath = smbRemotePath(config.remotePath), !smbPath.subpath.isEmpty else {
            return config.mountPoint
        }
        return URL(fileURLWithPath: config.mountPoint)
            .deletingLastPathComponent()
            .appendingPathComponent(".AutoVolumeBacking", isDirectory: true)
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
            .path
    }

    public func exposedPathTarget(for config: VolumeConfig) -> String? {
        guard config.protocolType == .smb,
              let smbPath = smbRemotePath(config.remotePath),
              !smbPath.subpath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: effectiveMountPoint(for: config))
            .appendingPathComponent(smbPath.subpath, isDirectory: true)
            .path
    }

    public func browsePath(for config: VolumeConfig) -> String {
        exposedPathTarget(for: config) ?? config.mountPoint
    }

    public func shouldOpenFinderAfterMount(for config: VolumeConfig) -> Bool {
        config.protocolType != .webdav
    }

    public func unmountTarget(for config: VolumeConfig) -> String {
        effectiveMountPoint(for: config)
    }

    private func quietMountPlan(for config: VolumeConfig, password: String?) throws -> CommandPlan {
        switch config.protocolType {
        case .smb:
            return CommandPlan(
                executable: "/sbin/mount_smbfs",
                arguments: ["-o", "nopassprompt,soft", try smbFileSystemURL(config: config, password: password), effectiveMountPoint(for: config)]
            )
        case .webdav:
            return try appleScriptMountPlan(url: webDAVURLString(config: config, includeUser: false), username: config.username, password: password)
        case .afp:
            return CommandPlan(
                executable: "/sbin/mount_afp",
                arguments: ["-s", try urlString(scheme: "afp", config: config, includeUser: true, password: password), config.mountPoint]
            )
        case .nfs:
            return CommandPlan(executable: "/sbin/mount_nfs", arguments: ["-o", "soft", "\(hostOnly(config.server)):\(nfsRemotePath(config.remotePath))", config.mountPoint])
        }
    }

    public func unmountPlan(mountPoint: String) -> CommandPlan {
        CommandPlan(executable: "/usr/sbin/diskutil", arguments: ["unmount", mountPoint])
    }

    public func forceUnmountPlan(mountPoint: String) -> CommandPlan {
        CommandPlan(executable: "/sbin/umount", arguments: ["-f", mountPoint])
    }

    private func urlString(scheme: String, config: VolumeConfig, includeUser: Bool = true, password: String? = nil) throws -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = hostOnly(config.server)
        components.path = normalizedRemotePath(config.remotePath)
        if includeUser, let username = config.username, !username.isEmpty {
            components.user = username
            if let password, !password.isEmpty {
                components.password = password
            }
        }
        guard let value = components.url?.absoluteString else { throw MountPlanningError.invalidURL }
        return value
    }

    private func webDAVURLString(config: VolumeConfig, includeUser: Bool = true, password: String? = nil) throws -> String {
        let rawServer = config.server.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverWithScheme = rawServer.contains("://") ? rawServer : "https://\(rawServer)"
        guard var components = URLComponents(string: serverWithScheme) else {
            throw MountPlanningError.invalidURL
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let remotePath = config.remotePath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let combinedPath = [basePath, remotePath].filter { !$0.isEmpty }.joined(separator: "/")
        components.path = combinedPath.isEmpty ? "" : "/\(combinedPath)"
        if includeUser, let username = config.username, !username.isEmpty {
            components.user = username
            if let password, !password.isEmpty {
                components.password = password
            }
        }
        guard let value = components.url?.absoluteString else { throw MountPlanningError.invalidURL }
        return value
    }

    private func smbFileSystemURL(config: VolumeConfig, password: String?) throws -> String {
        guard let smbPath = smbRemotePath(config.remotePath) else { throw MountPlanningError.invalidURL }
        var components = URLComponents()
        components.scheme = "smb"
        components.host = hostOnly(config.server)
        components.path = "/\(smbPath.share)"
        if let username = config.username, !username.isEmpty {
            components.user = username
            if let password, !password.isEmpty {
                components.password = password
            }
        }
        guard let value = components.url?.absoluteString else { throw MountPlanningError.invalidURL }
        return value.replacingOccurrences(of: "smb://", with: "//")
    }

    private func smbRemotePath(_ path: String) -> (share: String, subpath: String)? {
        let parts = path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard let share = parts.first else { return nil }
        return (share, parts.dropFirst().joined(separator: "/"))
    }

    private func appleScriptMountPlan(url: String, username: String?, password: String?) throws -> CommandPlan {
        let escapedURL = appleScriptEscaped(url)
        let script: String
        if let username, !username.isEmpty, let password, !password.isEmpty {
            script = """
            mount volume "\(escapedURL)" as user name "\(appleScriptEscaped(username))" with password "\(appleScriptEscaped(password))"
            """
        } else if let username, !username.isEmpty {
            script = """
            mount volume "\(escapedURL)" as user name "\(appleScriptEscaped(username))"
            """
        } else {
            script = """
            mount volume "\(escapedURL)"
            """
        }
        return CommandPlan(executable: "/usr/bin/osascript", arguments: ["-"], standardInput: script)
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func normalizedRemotePath(_ path: String) -> String {
        let normalized = path
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalized.isEmpty ? "" : "/\(normalized)"
    }

    private func nfsRemotePath(_ path: String) -> String {
        let normalized = normalizedRemotePath(path)
        return normalized.isEmpty ? "/" : normalized
    }

    private func hostOnly(_ server: String) -> String {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed), let host = components.host {
            return host
        }
        return trimmed
            .split(separator: "/")
            .first?
            .split(separator: ":")
            .first
            .map(String.init) ?? trimmed
    }
}
