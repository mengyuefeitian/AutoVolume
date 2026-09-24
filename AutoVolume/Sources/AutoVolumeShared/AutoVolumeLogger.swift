import Foundation
import Darwin

public final class AutoVolumeLogger {
    /// `Logs/AutoVolume.log`: app lifecycle, environment line, UI actions, main-thread
    /// stall watchdog, network mounts (SMB/WebDAV/AFP/NFS, both app and agent checks),
    /// and updates. Kept in one file so the stall watchdog, WebDAV phase timings, and
    /// agent checks can be read on a single timeline.
    public static let shared = AutoVolumeLogger()
    /// `Logs/NTFS.log`: everything NTFS from both the app and the agent (DiskArbitration
    /// events, eligibility/skip reasons, driver install, helper request/response). Kept
    /// separate so it isn't buried under the agent's periodic network checks.
    public static let ntfs = AutoVolumeLogger(fileName: "NTFS.log")

    public let logFileURL: URL
    public let retentionInterval: TimeInterval
    public let maxBytes: Int

    private let settingsStore: AppSettingsStore
    private let lock = NSLock()
    private let calendar = ISO8601DateFormatter()

    public static let defaultAppSupportDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first!
        .appendingPathComponent("AutoVolume", isDirectory: true)

    public init(
        directory: URL? = nil,
        fileName: String = "AutoVolume.log",
        retentionInterval: TimeInterval = 7 * 24 * 60 * 60,
        maxBytes: Int = 10 * 1024 * 1024,
        settingsStore: AppSettingsStore? = nil,
        settingsDirectory: URL? = nil
    ) {
        let appSupportDirectory = settingsDirectory ?? Self.defaultAppSupportDirectory
        let logsDirectory = directory ?? appSupportDirectory.appendingPathComponent("Logs", isDirectory: true)
        self.logFileURL = logsDirectory.appendingPathComponent(fileName)
        self.retentionInterval = retentionInterval
        self.maxBytes = maxBytes
        self.settingsStore = settingsStore ?? JSONAppSettingsStore(directory: appSupportDirectory)
        calendar.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        calendar.timeZone = .current
    }

    /// If `<appSupportDirectory>/AutoVolume.log` (the pre-Logs-directory layout) exists
    /// and `Logs/AutoVolume.log` does not, moves the legacy file into `Logs/` and removes
    /// its old lock file. Never loses or duplicates content: if the move fails for any
    /// reason, logging simply continues at the new location and the old file is left in
    /// place rather than risking data loss. Must be called once at process start, before
    /// the first log line is written.
    public static func migrateLegacyLogIfNeeded(appSupportDirectory: URL = AutoVolumeLogger.defaultAppSupportDirectory) {
        let legacyLogURL = appSupportDirectory.appendingPathComponent("AutoVolume.log")
        let legacyLockURL = appSupportDirectory.appendingPathComponent(".AutoVolume.log.lock")
        let logsDirectory = appSupportDirectory.appendingPathComponent("Logs", isDirectory: true)
        let newLogURL = logsDirectory.appendingPathComponent("AutoVolume.log")

        guard FileManager.default.fileExists(atPath: legacyLogURL.path),
              !FileManager.default.fileExists(atPath: newLogURL.path) else {
            return
        }

        do {
            try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: legacyLogURL, to: newLogURL)
            try? FileManager.default.removeItem(at: legacyLockURL)
        } catch {
            fputs("AutoVolume log migration error: \(error)\n", stderr)
        }
    }

    public var logDirectoryURL: URL {
        logFileURL.deletingLastPathComponent()
    }

    public func info(_ message: String) {
        guard isEnabled(.info) else { return }
        write(level: "INFO", message: message)
    }

    public func warning(_ message: String) {
        guard isEnabled(.warning) else { return }
        write(level: "WARN", message: message)
    }

    public func error(_ message: String) {
        guard isEnabled(.error) else { return }
        write(level: "ERROR", message: message)
    }

    private func isEnabled(_ level: LogLevel) -> Bool {
        let threshold = (try? settingsStore.load())?.logLevel ?? .info
        return level >= threshold
    }

    public func write(level: String, message: String, date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        do {
            try FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
            try withInterprocessLock {
                try pruneLocked(now: date)
                let cleanedMessage = message
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                let line = "\(calendar.string(from: date)) [\(level)] \(CommandResult.redacted(cleanedMessage))\n"
                if let data = line.data(using: .utf8) {
                    let existingData = (try? Data(contentsOf: logFileURL)) ?? Data()
                    var combinedData = Data()
                    combinedData.append(data)
                    combinedData.append(existingData)
                    if FileManager.default.fileExists(atPath: logFileURL.path) {
                        try combinedData.write(to: logFileURL, options: .atomic)
                    } else {
                        try data.write(to: logFileURL, options: .atomic)
                    }
                }
                try pruneLocked(now: date)
            }
        } catch {
            fputs("AutoVolume log error: \(error)\n", stderr)
        }
    }

    public func prune(now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
        try withInterprocessLock {
            try pruneLocked(now: now)
        }
    }

    private func withInterprocessLock<T>(_ operation: () throws -> T) throws -> T {
        let lockURL = logDirectoryURL.appendingPathComponent(".\(logFileURL.lastPathComponent).lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return try operation() }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }

    private func pruneLocked(now: Date) throws {
        guard FileManager.default.fileExists(atPath: logFileURL.path) else { return }
        let data = try Data(contentsOf: logFileURL)
        guard !data.isEmpty else { return }

        var lines = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }

        let cutoff = now.addingTimeInterval(-retentionInterval)
        lines = lines.filter { line in
            guard let date = datePrefix(from: line) else { return true }
            return date >= cutoff
        }
        lines.sort { left, right in
            switch (datePrefix(from: left), datePrefix(from: right)) {
            case let (leftDate?, rightDate?):
                return leftDate > rightDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return false
            }
        }

        var prunedData = Data(lines.joined(separator: "\n").utf8)
        if !lines.isEmpty {
            prunedData.append(0x0A)
        }
        if prunedData.count > maxBytes {
            prunedData = newestPrefix(from: lines, maxBytes: maxBytes)
        }
        try prunedData.write(to: logFileURL, options: .atomic)
    }

    private func datePrefix(from line: String) -> Date? {
        guard let end = line.firstIndex(of: " ") else { return nil }
        return calendar.date(from: String(line[..<end]))
    }

    private func newestPrefix(from lines: [String], maxBytes: Int) -> Data {
        var selected: [String] = []
        var totalBytes = 0
        for line in lines {
            let lineBytes = Data((line + "\n").utf8).count
            if lineBytes > maxBytes {
                selected = [String(line.prefix(maxBytes / 2))]
                break
            }
            guard totalBytes + lineBytes <= maxBytes else { break }
            selected.append(line)
            totalBytes += lineBytes
        }
        return Data(selected.joined(separator: "\n").appending(selected.isEmpty ? "" : "\n").utf8)
    }
}
