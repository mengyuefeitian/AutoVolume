import Foundation

/// Builds a single zip a user can send us that contains everything needed to diagnose a
/// WebDAV stall or an NTFS mount/copy failure from their machine: the app's own logs
/// (redacted), the root helper's log, a snapshot of the environment, the saved volume
/// list (with usernames redacted), and a short window of the unified log for the
/// NTFS/WebDAV-related processes. Never includes `credentials.*` or unredacted secrets.
public struct DiagnosticsExporter {
    private let appLogURL: URL
    private let ntfsLogURL: URL?
    private let helperLogURL: URL
    private let volumesConfigURL: URL
    private let unifiedLogWindow: String?
    private let commandRunner: CommandRunner
    private let privilegedHelperToolPath: String
    private let appBundle: Bundle

    public init(
        appLogURL: URL = AutoVolumeLogger.shared.logFileURL,
        ntfsLogURL: URL? = nil,
        helperLogURL: URL = URL(fileURLWithPath: "/var/log/com.autovolume.ntfshelper.log"),
        volumesConfigURL: URL = JSONConfigStore().fileURL,
        unifiedLogWindow: String? = "2h",
        commandRunner: CommandRunner = ProcessCommandRunner(),
        privilegedHelperToolPath: String = "/Library/PrivilegedHelperTools/com.autovolume.ntfsdriver",
        appBundle: Bundle = .main
    ) {
        self.appLogURL = appLogURL
        self.ntfsLogURL = ntfsLogURL
        self.helperLogURL = helperLogURL
        self.volumesConfigURL = volumesConfigURL
        self.unifiedLogWindow = unifiedLogWindow
        self.commandRunner = commandRunner
        self.privilegedHelperToolPath = privilegedHelperToolPath
        self.appBundle = appBundle
    }

    public func export(to directory: URL) throws -> URL {
        let timestampFormatter = DateFormatter()
        timestampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        timestampFormatter.timeZone = .current
        let baseName = "AutoVolume-diagnostics-\(timestampFormatter.string(from: Date()))"

        let stagingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleDirectory = stagingDirectory.appendingPathComponent(baseName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        try FileManager.default.createDirectory(at: bundleDirectory.appendingPathComponent("Logs"), withIntermediateDirectories: true)

        copyRedactedLog(from: appLogURL, to: bundleDirectory.appendingPathComponent("Logs/AutoVolume.log"))
        if let ntfsLogURL {
            copyRedactedLog(from: ntfsLogURL, to: bundleDirectory.appendingPathComponent("Logs/NTFS.log"))
        }
        copyRedactedLog(from: helperLogURL, to: bundleDirectory.appendingPathComponent("ntfshelper.log"))
        writeEnvironmentFile(to: bundleDirectory.appendingPathComponent("environment.txt"))
        writeRedactedVolumesConfig(to: bundleDirectory.appendingPathComponent("volumes.json"))
        if let unifiedLogWindow {
            writeUnifiedLog(window: unifiedLogWindow, to: bundleDirectory.appendingPathComponent("unified.log"))
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let zipURL = directory.appendingPathComponent("\(baseName).zip")
        let dittoResult = try commandRunner.run(CommandPlan(
            executable: "/usr/bin/ditto",
            arguments: ["-c", "-k", "--keepParent", bundleDirectory.path, zipURL.path]
        ))
        guard dittoResult.exitCode == 0 else {
            throw DiagnosticsExporterError.zipFailed(dittoResult.stderr)
        }
        return zipURL
    }

    private func copyRedactedLog(from source: URL, to destination: URL) {
        guard let data = try? Data(contentsOf: source), let text = String(data: data, encoding: .utf8) else { return }
        let redacted = CommandResult.redacted(text)
        try? redacted.data(using: .utf8)?.write(to: destination, options: .atomic)
    }

    private func writeRedactedVolumesConfig(to destination: URL) {
        guard let data = try? Data(contentsOf: volumesConfigURL) else { return }
        guard var configs = try? JSONDecoder().decode([VolumeConfig].self, from: data) else { return }
        for index in configs.indices where configs[index].username != nil {
            configs[index].username = "<redacted>"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let redactedData = try? encoder.encode(configs) else { return }
        try? redactedData.write(to: destination, options: .atomic)
    }

    private func writeEnvironmentFile(to destination: URL) {
        var lines: [String] = []
        let info = appBundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "-"
        let build = info["CFBundleVersion"] as? String ?? "-"
        lines.append("AutoVolume \(version) (\(build))")
        lines.append("")
        lines.append("$ sw_vers")
        lines.append(run("/usr/bin/sw_vers", []))
        lines.append("$ uname -m")
        lines.append(run("/usr/bin/uname", ["-m"]))
        lines.append("$ mount")
        lines.append(run("/sbin/mount", []))
        lines.append("$ ls -la \(privilegedHelperToolPath)")
        lines.append(run("/bin/ls", ["-la", privilegedHelperToolPath]))
        let text = CommandResult.redacted(lines.joined(separator: "\n") + "\n")
        try? text.data(using: .utf8)?.write(to: destination, options: .atomic)
    }

    private func run(_ executable: String, _ arguments: [String]) -> String {
        guard let result = try? commandRunner.run(CommandPlan(executable: executable, arguments: arguments)) else {
            return "(failed to run \(executable))"
        }
        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        return output.isEmpty ? "(no output)" : output
    }

    /// `log show` is not bounded by anything in `CommandRunner`, so this runs it directly
    /// with a hard 30s timeout: a stuck or unusually large unified-log query must never
    /// block a diagnostics export indefinitely.
    private func writeUnifiedLog(window: String, to destination: URL) {
        let predicate = #"process == "ntfs-3g" OR process BEGINS WITH "go-nfsv4" OR process == "webdavfs_agent" OR process == "NetAuthAgent" OR process == "AutoVolume" OR process == "AutoVolumeAgent""#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--last", window, "--style", "compact", "--predicate", predicate]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else {
            try? "(failed to run log show)".data(using: .utf8)?.write(to: destination, options: .atomic)
            return
        }

        let timeoutWorkItem = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeoutWorkItem)

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWorkItem.cancel()

        let text = String(data: data, encoding: .utf8) ?? ""
        let redacted = CommandResult.redacted(text)
        try? redacted.data(using: .utf8)?.write(to: destination, options: .atomic)
    }
}

public enum DiagnosticsExporterError: Error, LocalizedError {
    case zipFailed(String)

    public var errorDescription: String? {
        switch self {
        case .zipFailed(let message):
            return L10n.t(.errorDiagnosticsZipFailed, message)
        }
    }
}
