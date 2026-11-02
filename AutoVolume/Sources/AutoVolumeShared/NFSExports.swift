import Foundation
import Darwin

/// Runs a command and gives up after `timeout`, killing it. `showmount -e` waits on RPC timeouts for
/// well over a minute against a host that is down, so nothing that needs an answer may run it unbounded.
public enum TimedCommand {
    /// Collects a pipe's output on its own thread, so a command that writes more than the pipe buffer
    /// (64 KB) is not mistaken for a hang.
    final class Collector: @unchecked Sendable {
        private(set) var data = Data()
        private let finished = DispatchGroup()

        init(reading handle: FileHandle) {
            finished.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                data = handle.readDataToEndOfFile()
                finished.leave()
            }
        }

        /// Returns once the pipe has reached EOF (the process exited or was killed).
        func wait(upTo timeout: TimeInterval) -> Data {
            _ = finished.wait(timeout: .now() + timeout)
            return data
        }
    }

    /// The command's result, or `nil` if it could not start or did not finish within `timeout`.
    public static func run(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult? {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return nil
        }
        let out = Collector(reading: stdout.fileHandleForReading)
        let err = Collector(reading: stderr.fileHandleForReading)

        let exited = DispatchGroup()
        exited.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            exited.leave()
        }
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        // Either way the pipes now reach EOF; join the readers so no file descriptor or thread is left
        // behind, then release the handles.
        let stdoutData = out.wait(upTo: 1)
        let stderrData = err.wait(upTo: 1)
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
        guard !timedOut else { return nil }
        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}

/// What the server's export list says about a path the user typed.
public enum NFSExportResolution: Equatable {
    /// The path is exported, or is a folder inside an export: mount it as written.
    case exported(path: String)
    /// Not exported as written, but exactly one export matches by name; this is the full path to use.
    case matched(path: String)
    /// Nothing matches; `available` is everything the server exports.
    case notExported(available: [String])
    /// Several exports match equally well, so guessing would be wrong.
    case ambiguous(candidates: [String])
}

/// NFS mounts by the server's *export path*, which is not the share name SMB uses. A Synology exports
/// `/volume1/video` for the share `video`, and `mount_nfs host:/video` is refused with
/// "Permission denied" — the same text it gives when the client is not allowed, which made this look
/// like a permissions problem. This reads the server's export list and maps a typed path onto it.
public enum NFSExportResolver {
    /// Export paths from `showmount -e` output (first column of every line after the header).
    public static func parseExports(showmountOutput: String) -> [String] {
        showmountOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                guard !line.hasPrefix("Exports list") else { return nil }
                guard let first = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
                      first.hasPrefix("/") else { return nil }
                return String(first)
            }
    }

    public static func resolve(requested: String, exports: [String]) -> NFSExportResolution {
        let wanted = components(of: requested)
        let exportComponents = exports.map { (path: $0, parts: components(of: $0)) }

        // The typed path starts at an export: use it as written (a folder inside an export is mountable).
        if exportComponents.contains(where: { wanted.starts(with: $0.parts) }) || wanted.isEmpty && exports.contains("/") {
            return .exported(path: join(wanted))
        }

        // Otherwise match by name: the tail of an export equals the head of what was typed
        // ("video" or "/video" -> "/volume1/video"), preferring the longest overlap.
        var best = 0
        var candidates: [String] = []
        for export in exportComponents {
            let overlap = (1...max(1, min(export.parts.count, wanted.count))).reversed().first { count in
                guard count <= export.parts.count, count <= wanted.count else { return false }
                return zip(export.parts.suffix(count), wanted.prefix(count)).allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
            } ?? 0
            guard overlap > 0, overlap >= best else { continue }
            let resolved = join(export.parts + wanted.dropFirst(overlap))
            if overlap > best {
                best = overlap
                candidates = [resolved]
            } else if !candidates.contains(resolved) {
                candidates.append(resolved)
            }
        }
        switch candidates.count {
        case 0: return .notExported(available: exports)
        case 1: return .matched(path: candidates[0])
        default: return .ambiguous(candidates: candidates.sorted())
        }
    }

    private static func components(of path: String) -> [String] {
        path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func join(_ parts: [String]) -> String {
        "/" + parts.joined(separator: "/")
    }

    private static func join(_ parts: ArraySlice<String>) -> String { join(Array(parts)) }
}

/// Where a server's exports come from. Injectable so tests and the agent never shell out.
public protocol NFSExportListing {
    /// The server's exported paths, or `nil` when they could not be listed (RPC blocked, host down).
    func exports(host: String) -> [String]?
}

/// `showmount -e <host>` with a hard timeout. Call it from user-initiated flows on a background
/// thread, after the server's NFS port is known to answer — never from the main thread.
public struct ShowmountExportLister: NFSExportListing {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 4) {
        self.timeout = timeout
    }

    public func exports(host: String) -> [String]? {
        // This blocks for up to `timeout`; refuse rather than freeze the UI if a caller ever gets it wrong.
        guard !Thread.isMainThread else { return nil }
        guard let result = TimedCommand.run(executable: "/usr/bin/showmount", arguments: ["-e", host], timeout: timeout),
              result.exitCode == 0 else {
            return nil
        }
        return NFSExportResolver.parseExports(showmountOutput: result.stdout)
    }
}

public extension NFSExportResolver {
    /// The exports of the server the user typed (it may carry a port or brackets). `nil` when unavailable.
    static func exports(forServer server: String, lister: NFSExportListing = ShowmountExportLister()) -> [String]? {
        let host = ConnectivityTester().hostOnly(server)
        return host.isEmpty ? nil : lister.exports(host: host)
    }

    /// Resolves a configured NFS volume against its server's exports. `nil` when the server's export
    /// list is unavailable, in which case the path should be used as typed.
    static func resolution(for config: VolumeConfig, lister: NFSExportListing = ShowmountExportLister()) -> (resolution: NFSExportResolution, exports: [String])? {
        guard config.protocolType == .nfs else { return nil }
        let host = ConnectivityTester().hostOnly(config.server)
        guard !host.isEmpty, let exports = lister.exports(host: host) else { return nil }
        return (resolve(requested: config.remotePath, exports: exports), exports)
    }
}

/// A user-facing explanation for an NFS mount failure.
public struct NFSMountDiagnosis: Equatable {
    public let key: L10nKey
    public let args: [String]
}

/// `mount_nfs` reports "Permission denied" both when the path is not exported and when the client is
/// not allowed, and "Operation not permitted" when macOS itself refuses (a mount point the user does
/// not own, or a root-only option). Telling them apart is the whole point of this.
public enum NFSMountDiagnostics {
    /// `homeDirectory` is injectable for tests.
    public static func diagnose(stderr: String, requestedPath: String, exports: [String]?, homeDirectory: String = NSHomeDirectory()) -> NFSMountDiagnosis? {
        let text = stderr.lowercased()
        if text.contains("operation not permitted") {
            // Only blame the mount point's location when it is outside the user's own folder; a mount point
            // already in the home folder means something else is wrong, and moving it would not help.
            if let mountPoint = mountPoint(in: stderr), mountPoint == homeDirectory || mountPoint.hasPrefix(homeDirectory + "/") {
                return nil
            }
            return NFSMountDiagnosis(key: .errorNFSNotPermitted, args: [])
        }
        guard text.contains("permission denied") else { return nil }

        if let exports {
            switch NFSExportResolver.resolve(requested: requestedPath, exports: exports) {
            case .exported:
                break
            case .matched, .notExported, .ambiguous:
                return NFSMountDiagnosis(key: .errorNFSExportNotFound, args: [exports.isEmpty ? "—" : exports.joined(separator: ", ")])
            }
        }
        return NFSMountDiagnosis(key: .errorNFSAccessDenied, args: [])
    }

    /// The mount point in `mount_nfs: can't mount /x from host onto /mount/point: reason`.
    private static func mountPoint(in stderr: String) -> String? {
        guard let onto = stderr.range(of: " onto ") else { return nil }
        let rest = stderr[onto.upperBound...]
        guard let end = rest.range(of: ": ") else { return nil }
        let path = String(rest[..<end.lowerBound])
        return path.hasPrefix("/") ? path : nil
    }
}
