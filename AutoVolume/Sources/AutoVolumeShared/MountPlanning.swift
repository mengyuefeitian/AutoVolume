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
            return CommandPlan(executable: "/usr/bin/open", arguments: [try urlString(scheme: "webdav", config: config)])
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
}
