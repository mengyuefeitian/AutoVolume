import Foundation

public struct ConnectivityCheckResult: Equatable {
    public var isReachable: Bool
    public var message: String?

    public init(isReachable: Bool, message: String? = nil) {
        self.isReachable = isReachable
        self.message = message
    }
}

public struct ConnectivityTester {
    public init() {}

    public func testPlan(for config: VolumeConfig, password: String?) throws -> CommandPlan {
        switch config.protocolType {
        case .webdav:
            var arguments = [
                "--fail-with-body",
                "--silent",
                "--show-error",
                "--request", "PROPFIND",
                "--header", "Depth: 0",
                "--max-time", "10",
                try webDAVURLString(config: config)
            ]
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

    public func checkResult(for config: VolumeConfig, result: CommandResult) -> ConnectivityCheckResult {
        guard result.exitCode != 0 else {
            return ConnectivityCheckResult(isReachable: true)
        }

        let combined = "\(result.stdout)\n\(result.stderr)"
        let normalized = combined.lowercased()

        if config.protocolType == .webdav {
            if normalized.contains("401") || normalized.contains("unauthorized") {
                return ConnectivityCheckResult(
                    isReachable: false,
                    message: "WebDAV authentication failed (401 Unauthorized). Check the username, password, and account permission for this remote path."
                )
            }
            if normalized.contains("403") || normalized.contains("forbidden") {
                return ConnectivityCheckResult(
                    isReachable: false,
                    message: "WebDAV access was denied (403 Forbidden). Check whether this account can access the configured remote path."
                )
            }
            if normalized.contains("404") || normalized.contains("not found") {
                return ConnectivityCheckResult(
                    isReachable: false,
                    message: "WebDAV remote path was not found. Check the remote path format and folder name."
                )
            }
        }

        if result.exitCode == 124 || isNetworkFailureMessage(normalized) {
            return ConnectivityCheckResult(
                isReachable: false,
                message: "\(displayName(for: config.protocolType)) server is not reachable now. AutoVolume will retry after the network returns."
            )
        }

        switch config.protocolType {
        case .smb:
            return ConnectivityCheckResult(
                isReachable: false,
                message: "SMB server is not reachable on port 445. AutoVolume will retry after the network returns."
            )
        case .afp:
            return ConnectivityCheckResult(
                isReachable: false,
                message: "AFP server is not reachable on port 548. AutoVolume will retry after the network returns."
            )
        case .nfs:
            return ConnectivityCheckResult(
                isReachable: false,
                message: "NFS server is not reachable on port 2049. Check the NFS service, firewall, export path, or network access."
            )
        case .webdav:
            break
        }

        let detail = result.stderr.isEmpty ? result.stdout : result.stderr
        let trimmed = CommandResult.redacted(detail).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return ConnectivityCheckResult(isReachable: false, message: trimmed)
        }

        return ConnectivityCheckResult(
            isReachable: false,
            message: "\(displayName(for: config.protocolType)) connection test failed with exit code \(result.exitCode)."
        )
    }

    private func webDAVURLString(config: VolumeConfig) throws -> String {
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
        guard let value = components.url?.absoluteString else { throw MountPlanningError.invalidURL }
        return value
    }

    private func hostOnly(_ server: String) -> String {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed), let host = components.host {
            return host
        }
        let withoutScheme = trimmed.contains("://")
            ? (URLComponents(string: trimmed)?.host ?? trimmed)
            : trimmed
        return withoutScheme
            .split(separator: "/")
            .first?
            .split(separator: ":")
            .first
            .map(String.init) ?? trimmed
    }

    private func displayName(for protocolType: VolumeProtocol) -> String {
        switch protocolType {
        case .smb: return "SMB"
        case .webdav: return "WebDAV"
        case .afp: return "AFP"
        case .nfs: return "NFS"
        }
    }

    private func isNetworkFailureMessage(_ normalizedMessage: String) -> Bool {
        [
            "could not resolve host",
            "couldn't connect",
            "could not connect",
            "connection refused",
            "connection reset",
            "failed to connect",
            "host is down",
            "network is down",
            "network is unreachable",
            "no route to host",
            "operation timed out",
            "server unavailable",
            "timed out",
            "timeout"
        ].contains { normalizedMessage.contains($0) }
    }
}
