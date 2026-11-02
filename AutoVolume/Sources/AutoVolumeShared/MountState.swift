import Foundation
import Darwin

public protocol MountStateProvider {
    func isMounted(config: VolumeConfig) -> Bool
}

public final class FileSystemMountStateProvider: MountStateProvider {
    private let fileManager: FileManager
    private let mountPlanner: MountPlanner
    private let mountTable: SystemMountTable?
    private let healthCheckTimeout: TimeInterval
    private let validatesResponsiveness: Bool

    /// `mountTable` is injectable for tests; production passes `nil` and every check reads the live
    /// `mount` output exactly once.
    public init(
        fileManager: FileManager = .default,
        mountPlanner: MountPlanner = MountPlanner(),
        mountTable: SystemMountTable? = nil,
        healthCheckTimeout: TimeInterval = 5,
        validatesResponsiveness: Bool = true
    ) {
        self.fileManager = fileManager
        self.mountPlanner = mountPlanner
        self.mountTable = mountTable
        self.healthCheckTimeout = healthCheckTimeout
        self.validatesResponsiveness = validatesResponsiveness
    }

    public func isMounted(config: VolumeConfig) -> Bool {
        mountStatus(config: config).isMounted
    }

    /// What is actually mounted for `config`. A volume counts as mounted only when the system mount
    /// table holds an entry of the right filesystem, from the right server and share/export, *at the
    /// mount point this volume is supposed to occupy* (WebDAV is the exception: the system picks its
    /// mount point). Merely finding something mounted at `config.mountPoint` is not enough — that is
    /// how an SMB mount made the same-named NFS volume look healthy (issue #3), and how a path that
    /// was only a leftover empty directory could look healthy.
    public func mountStatus(config: VolumeConfig) -> MountStatus {
        let table = (mountTable ?? SystemMountTable()).snapshot()
        guard let candidates = table.entries(matching: config) else {
            // `mount` itself failed, so there is no table to judge by; fall back to the OS volume list.
            return legacyMountStatus(config: config)
        }

        let expectedMountPoint = expectedMountPoint(for: config)
        let live: MountEntry?
        if let expectedMountPoint {
            live = candidates.first { SystemMountTable.samePath($0.mountPoint, expectedMountPoint) }
        } else {
            live = candidates.first
        }
        guard let live else {
            return MountStatus(isMounted: false, entry: nil, foundElsewhere: candidates.first)
        }
        let healthPath = mountPlanner.exposedPathTarget(for: config) ?? live.mountPoint
        guard !validatesResponsiveness || PathHealthProbe(timeout: healthCheckTimeout).isResponsive(path: healthPath) else {
            return MountStatus(isMounted: false, entry: live, foundElsewhere: nil, isStale: true)
        }
        return MountStatus(isMounted: true, entry: live, foundElsewhere: nil)
    }

    private func expectedMountPoint(for config: VolumeConfig) -> String? {
        config.protocolType == .webdav ? nil : mountPlanner.effectiveMountPoint(for: config)
    }

    private func legacyMountStatus(config: VolumeConfig) -> MountStatus {
        let mountURL = URL(fileURLWithPath: config.mountPoint)
        guard let mountedURLs = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []),
              fileManager.fileExists(atPath: mountURL.path),
              mountedURLs.contains(where: { $0.standardizedFileURL.path == mountURL.standardizedFileURL.path }) else {
            return MountStatus(isMounted: false, entry: nil, foundElsewhere: nil)
        }
        let healthPath = mountPlanner.healthCheckPath(for: config, mountTable: SystemMountTable(mountOutput: ""))
        let responsive = !validatesResponsiveness || PathHealthProbe(timeout: healthCheckTimeout).isResponsive(path: healthPath)
        return MountStatus(isMounted: responsive, entry: nil, foundElsewhere: nil, isStale: !responsive)
    }
}

/// The outcome of looking for one configured volume in the system mount table.
public struct MountStatus: Equatable {
    public let isMounted: Bool
    /// The matching mount at this volume's expected mount point, when there is one.
    public let entry: MountEntry?
    /// A mount of the same share at a *different* path (for example mounted by Finder), when there is
    /// one and nothing is mounted at the expected path.
    public let foundElsewhere: MountEntry?
    /// Mounted per the table but the mount point did not answer (hung or dead session).
    public let isStale: Bool

    public init(isMounted: Bool, entry: MountEntry?, foundElsewhere: MountEntry?, isStale: Bool = false) {
        self.isMounted = isMounted
        self.entry = entry
        self.foundElsewhere = foundElsewhere
        self.isStale = isStale
    }
}

public struct PathHealthProbe {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }

    public func isResponsive(path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ls")
        process.arguments = ["-1", path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return false
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            group.leave()
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            return false
        }
        return process.terminationStatus == 0
    }
}

/// One line of `mount` output: `<source> on <mountPoint> (<fileSystem>, <options>...)`.
public struct MountEntry: Equatable {
    public let source: String
    public let mountPoint: String
    public let fileSystem: String

    public init(source: String, mountPoint: String, fileSystem: String) {
        self.source = source
        self.mountPoint = mountPoint
        self.fileSystem = fileSystem
    }
}

public struct SystemMountTable {
    private let mountOutput: String?
    /// `mount` was run and failed: there is no table to judge by (as opposed to an empty one).
    private let isUnavailable: Bool

    public init(mountOutput: String? = nil) {
        self.mountOutput = mountOutput
        self.isUnavailable = false
    }

    /// A table known to be unreadable; used for the result of a failed `snapshot()`.
    public init(unavailable: Bool) {
        self.mountOutput = nil
        self.isUnavailable = unavailable
    }

    /// Captures the current `mount` output once so repeated queries (and the health probe that
    /// follows) don't each spawn a `/sbin/mount` process. A table built from fixed output, or already
    /// known to be unreadable, is returned unchanged; if `mount` fails the result is an unreadable
    /// table, so the failure is reported once rather than `mount` being run again by every query.
    public func snapshot() -> SystemMountTable {
        guard mountOutput == nil, !isUnavailable else { return self }
        let result = runMount()
        guard result.exitCode == 0 else { return SystemMountTable(unavailable: true) }
        return SystemMountTable(mountOutput: result.stdout)
    }

    /// Whether anything at all is mounted at exactly `path`.
    public func hasMount(atPath path: String) -> Bool {
        (allEntries() ?? []).contains { Self.samePath($0.mountPoint, path) }
    }

    /// Every mount that belongs to `config`'s server and share/export with the right filesystem,
    /// wherever it is mounted. `nil` when the mount table itself could not be read.
    public func entries(matching config: VolumeConfig) -> [MountEntry]? {
        guard let all = allEntries() else { return nil }
        return all.filter { matches(entry: $0, config: config) }
    }

    public func contains(config: VolumeConfig) -> Bool {
        !(entries(matching: config) ?? []).isEmpty
    }

    public func mountPoint(for config: VolumeConfig) -> String? {
        entries(matching: config)?.first?.mountPoint
    }

    /// Path equality that ignores trailing slashes and symlinks (`/tmp` vs `/private/tmp`).
    public static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        func normalized(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        }
        return normalized(lhs) == normalized(rhs)
    }

    // MARK: parsing

    private func allEntries() -> [MountEntry]? {
        guard !isUnavailable else { return nil }
        let output: String
        if let mountOutput {
            output = mountOutput
        } else {
            let result = runMount()
            guard result.exitCode == 0 else { return nil }
            output = result.stdout
        }
        return output.split(separator: "\n").compactMap { parseEntry(String($0)) }
    }

    private func parseEntry(_ line: String) -> MountEntry? {
        guard let onRange = line.range(of: " on "),
              let optionsRange = line.range(of: " (", options: .backwards),
              onRange.upperBound < optionsRange.lowerBound else {
            return nil
        }
        let options = line[optionsRange.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ")"))
        let fileSystem = options.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return MountEntry(
            source: String(line[..<onRange.lowerBound]),
            mountPoint: String(line[onRange.upperBound..<optionsRange.lowerBound]),
            fileSystem: fileSystem
        )
    }

    // MARK: matching

    private func matches(entry: MountEntry, config: VolumeConfig) -> Bool {
        guard entry.fileSystem == fileSystemName(for: config.protocolType) else { return false }
        let source = parsedSource(entry.source, fileSystem: entry.fileSystem)

        // AFP mount sources are opaque tokens with no host; for every other protocol the host must match.
        if let sourceHost = source.host {
            guard hostsMatch(sourceHost, hostOnly(config.server)) else { return false }
        } else if config.protocolType != .afp {
            return false
        }

        let remote = config.remotePath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        if remote.isEmpty { return true }
        let path = source.path.lowercased()

        switch config.protocolType {
        case .smb:
            // Only the share (first component) is part of an SMB mount source.
            guard let share = remote.split(separator: "/").first else { return true }
            return path.split(separator: "/").first.map(String.init) == String(share)
        case .nfs, .webdav:
            return path == remote || path.hasSuffix("/" + remote)
        case .afp:
            return true
        }
    }

    /// Host and path of a mount source, percent-decoded:
    /// - smbfs / afpfs `//[user[:pw]@]host/share[/...]`
    /// - nfs `host:/export`
    /// - webdav `https://[user@]host[:port]/path`
    private func parsedSource(_ source: String, fileSystem: String) -> (host: String?, path: String) {
        func decoded(_ value: String) -> String { value.removingPercentEncoding ?? value }

        if source.hasPrefix("//") {
            let rest = source.dropFirst(2)
            let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
            let authority = rest[..<authorityEnd]
            let host = (authority.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? String(authority))
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let path = authorityEnd < rest.endIndex ? String(rest[rest.index(after: authorityEnd)...]) : ""
            return (decoded(host).lowercased(), decoded(path).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
        if source.contains("://"), let components = URLComponents(string: source), let host = components.host {
            return (host.lowercased(), decoded(components.path).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
        if fileSystem == "nfs", source.hasPrefix("["), let close = source.firstIndex(of: "]") {
            let host = String(source[source.index(after: source.startIndex)..<close])
            let rest = source[source.index(after: close)...].drop { $0 == ":" }
            return (host.lowercased(), decoded(String(rest)).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
        if fileSystem == "nfs", let colon = source.firstIndex(of: ":") {
            let host = String(source[..<colon])
            let path = String(source[source.index(after: colon)...])
            return (host.lowercased(), decoded(path).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
        return (nil, decoded(source))
    }

    /// Exact host match, tolerating only a DNS suffix on a name (`nas` vs `nas.local`). IP literals are
    /// compared whole so `192.168.3.10` never matches `192.168.3.100`.
    private func hostsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let bracketed = CharacterSet(charactersIn: "[]")
        let a = lhs.trimmingCharacters(in: bracketed).lowercased()
        let b = rhs.trimmingCharacters(in: bracketed).lowercased()
        if a == b { return true }
        guard !Self.isIPv4Literal(a), !Self.isIPv4Literal(b) else { return false }
        return a.hasPrefix(b + ".") || b.hasPrefix(a + ".")
    }

    private static func isIPv4Literal(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private func fileSystemName(for protocolType: VolumeProtocol) -> String {
        switch protocolType {
        case .smb: "smbfs"
        case .webdav: "webdav"
        case .afp: "afpfs"
        case .nfs: "nfs"
        }
    }

    private func hostOnly(_ server: String) -> String {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        // A bare bracketed IPv6 literal ("[fe80::1]" or "[fe80::1]:445"): everything inside the brackets.
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        }
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

    private func runMount() -> CommandResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount")
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
            return CommandResult(
                exitCode: process.terminationStatus,
                stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            )
        } catch {
            return CommandResult(exitCode: 1, stdout: "", stderr: error.localizedDescription)
        }
    }
}
