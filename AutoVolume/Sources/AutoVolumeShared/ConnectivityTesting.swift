import Foundation

public struct ConnectivityCheckResult: Equatable {
    public var isReachable: Bool
    /// English rendering, for logs and callers that don't localize (e.g. `AutoVolumeLogger`).
    public var message: String?
    /// The key this failure was recorded under, if it came from a fixed hardcoded sentence.
    /// `nil` for the raw-command-output fallback, where there is no sentence to key.
    public var messageKey: L10nKey?
    public var messageArgs: [String]

    public init(isReachable: Bool, message: String? = nil, messageKey: L10nKey? = nil, messageArgs: [String] = []) {
        self.isReachable = isReachable
        self.message = message
        self.messageKey = messageKey
        self.messageArgs = messageArgs
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
                return failure(.errorConnectivityWebDAVUnauthorized)
            }
            if normalized.contains("403") || normalized.contains("forbidden") {
                return failure(.errorConnectivityWebDAVForbidden)
            }
            if normalized.contains("404") || normalized.contains("not found") {
                return failure(.errorConnectivityWebDAVNotFound)
            }
        }

        if result.exitCode == 124 || isNetworkFailureMessage(normalized) {
            return failure(.errorConnectivityUnreachable, args: [displayName(for: config.protocolType)])
        }

        switch config.protocolType {
        case .smb:
            return failure(.errorConnectivitySMBUnreachable)
        case .afp:
            return failure(.errorConnectivityAFPUnreachable)
        case .nfs:
            return failure(.errorConnectivityNFSUnreachable)
        case .webdav:
            break
        }

        // Raw command output, not a fixed sentence — nothing to key here. Stays English-only
        // (it's whatever curl/nc printed), same as before.
        let detail = result.stderr.isEmpty ? result.stdout : result.stderr
        let trimmed = CommandResult.redacted(detail).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return ConnectivityCheckResult(isReachable: false, message: trimmed)
        }

        return failure(.errorConnectivityTestFailed, args: [displayName(for: config.protocolType), String(result.exitCode)])
    }

    private func failure(_ key: L10nKey, args: [String] = []) -> ConnectivityCheckResult {
        ConnectivityCheckResult(
            isReachable: false,
            message: L10n.t(key, args: args, in: .en),
            messageKey: key,
            messageArgs: args
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
