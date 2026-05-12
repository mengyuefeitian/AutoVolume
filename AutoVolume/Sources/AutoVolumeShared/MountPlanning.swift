import Foundation

public enum MountPlanningError: Error, Equatable {
    case invalidURL
}

public struct MountPlanner {
    public init() {}

    public func mountPlan(for config: VolumeConfig, password: String?) throws -> CommandPlan {
        switch config.protocolType {
        case .smb:
            return CommandPlan(executable: "/usr/bin/open", arguments: [try urlString(scheme: "smb", config: config)])
        case .webdav:
            return CommandPlan(executable: "/sbin/mount_webdav", arguments: [try webDAVURLString(config: config), config.mountPoint])
        case .afp:
            return CommandPlan(executable: "/usr/bin/open", arguments: [try urlString(scheme: "afp", config: config)])
        case .nfs:
            return CommandPlan(executable: "/sbin/mount_nfs", arguments: ["\(config.server):\(config.remotePath)", config.mountPoint])
        }
    }

    public func unmountPlan(mountPoint: String) -> CommandPlan {
        CommandPlan(executable: "/usr/sbin/diskutil", arguments: ["unmount", mountPoint])
    }

    private func urlString(scheme: String, config: VolumeConfig) throws -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = config.server
        components.path = "/" + config.remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let username = config.username, !username.isEmpty {
            components.user = username
        }
        guard let value = components.url?.absoluteString else { throw MountPlanningError.invalidURL }
        return value
    }

    private func webDAVURLString(config: VolumeConfig) throws -> String {
        let rawServer = config.server.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverWithScheme = rawServer.contains("://") ? rawServer : "https://\(rawServer)"
        guard var components = URLComponents(string: serverWithScheme) else {
            throw MountPlanningError.invalidURL
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let remotePath = config.remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let combinedPath = [basePath, remotePath].filter { !$0.isEmpty }.joined(separator: "/")
        components.path = combinedPath.isEmpty ? "" : "/\(combinedPath)"
        if let username = config.username, !username.isEmpty {
            components.user = username
        }
        guard let value = components.url?.absoluteString else { throw MountPlanningError.invalidURL }
        return value
    }
}
