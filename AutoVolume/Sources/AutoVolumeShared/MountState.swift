import Foundation

public protocol MountStateProvider {
    func isMounted(config: VolumeConfig) -> Bool
}

public final class FileSystemMountStateProvider: MountStateProvider {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func isMounted(config: VolumeConfig) -> Bool {
        let mountURL = URL(fileURLWithPath: config.mountPoint)
        guard let mountedURLs = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) else {
            return false
        }
        if fileManager.fileExists(atPath: mountURL.path),
           mountedURLs.contains(where: { $0.standardizedFileURL.path == mountURL.standardizedFileURL.path }) {
            return true
        }
        return SystemMountTable().contains(config: config)
    }
}

public struct SystemMountTable {
    private let mountOutput: String?

    public init(mountOutput: String? = nil) {
        self.mountOutput = mountOutput
    }

    public func contains(config: VolumeConfig) -> Bool {
        let output: String
        if let mountOutput {
            output = mountOutput
        } else {
            let result = runMount()
            guard result.exitCode == 0 else { return false }
            output = result.stdout
        }
        return output
            .split(separator: "\n")
            .map(String.init)
            .contains { line in
                matches(line: line, config: config)
            }
    }

    private func matches(line: String, config: VolumeConfig) -> Bool {
        let lowercasedLine = line.lowercased()
        guard lowercasedLine.contains(fileSystemName(for: config.protocolType)) else { return false }
        guard lowercasedLine.contains(hostOnly(config.server).lowercased()) else { return false }

        let remotePath = config.remotePath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        if remotePath.isEmpty { return true }
        return lowercasedLine.contains("/\(remotePath)")
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
