import Foundation

public enum MountPlanningError: Error, Equatable {
    case invalidURL
}

public struct MountPlanner {
    public init() {}

    public func mountPlan(for config: VolumeConfig, password: String?) throws -> CommandPlan {
        switch config.protocolType {
        case .smb:
            return try appleScriptMountPlan(url: urlString(scheme: "smb", config: config, includeUser: false), username: config.username, password: password)
        case .webdav:
            return try appleScriptMountPlan(url: webDAVURLString(config: config, includeUser: false), username: config.username, password: password)
        case .afp:
            return try appleScriptMountPlan(url: urlString(scheme: "afp", config: config, includeUser: false), username: config.username, password: password)
        case .nfs:
            return CommandPlan(executable: "/sbin/mount_nfs", arguments: ["\(config.server):\(config.remotePath)", config.mountPoint])
        }
    }

    public func unmountPlan(mountPoint: String) -> CommandPlan {
        CommandPlan(executable: "/usr/sbin/diskutil", arguments: ["unmount", mountPoint])
    }

    private func urlString(scheme: String, config: VolumeConfig, includeUser: Bool = true) throws -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = config.server
        components.path = "/" + config.remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if includeUser, let username = config.username, !username.isEmpty {
            components.user = username
        }
        guard let value = components.url?.absoluteString else { throw MountPlanningError.invalidURL }
        return value
    }

    private func webDAVURLString(config: VolumeConfig, includeUser: Bool = true) throws -> String {
        let rawServer = config.server.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverWithScheme = rawServer.contains("://") ? rawServer : "https://\(rawServer)"
        guard var components = URLComponents(string: serverWithScheme) else {
            throw MountPlanningError.invalidURL
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let remotePath = config.remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let combinedPath = [basePath, remotePath].filter { !$0.isEmpty }.joined(separator: "/")
        components.path = combinedPath.isEmpty ? "" : "/\(combinedPath)"
        if includeUser, let username = config.username, !username.isEmpty {
            components.user = username
        }
        guard let value = components.url?.absoluteString else { throw MountPlanningError.invalidURL }
        return value
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
}
