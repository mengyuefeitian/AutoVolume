import Foundation

public struct ConnectivityTester {
    public init() {}

    public func testPlan(for config: VolumeConfig, password: String?) throws -> CommandPlan {
        switch config.protocolType {
        case .webdav:
            var arguments = ["--head", "--location", "--max-time", "10", try webDAVURLString(config: config)]
            if let username = config.username, !username.isEmpty, let password, !password.isEmpty {
                arguments.insert(contentsOf: ["--user", "\(username):\(password)"], at: 0)
            }
            return CommandPlan(executable: "/usr/bin/curl", arguments: arguments)
        case .smb:
            return CommandPlan(executable: "/usr/bin/nc", arguments: ["-z", "-G", "5", hostOnly(config.server), "445"])
        case .afp:
            return CommandPlan(executable: "/usr/bin/nc", arguments: ["-z", "-G", "5", hostOnly(config.server), "548"])
        case .nfs:
            return CommandPlan(executable: "/usr/bin/nc", arguments: ["-z", "-G", "5", hostOnly(config.server), "2049"])
        }
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
        guard let value = components.url?.absoluteString else { throw MountPlanningError.invalidURL }
        return value
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
