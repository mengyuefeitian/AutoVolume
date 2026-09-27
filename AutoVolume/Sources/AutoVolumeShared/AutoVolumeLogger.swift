import Foundation
import Darwin

/// `@unchecked Sendable` because every mutable access (`lock`, plus the interprocess `flock`
/// for on-disk state) is already serialized internally — see `write(level:message:date:)`.
public final class AutoVolumeLogger: @unchecked Sendable {
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
    /// Guards how often `write()` pays for the full retention/size prune (parses every
    /// existing line's timestamp). Without this throttle, every single log line — including
    /// ones written from the main thread (e.g. "Opened settings") or from a background timer
    /// holding the same lock (the stall watchdog's recovery log) — re-parsed the entire
    /// accumulated log history, so cost grew with total uptime instead of staying flat.
    private var lastAutoPruneDate: Date?
    private let autoPruneInterval: TimeInterval = 60

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
                let cleanedMessage = message
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                let line = "\(calendar.string(from: date)) [\(level)] \(CommandResult.redacted(cleanedMessage))\n"
                guard let data = line.data(using: .utf8) else { return }

                // Prepend the new line — the log is kept newest-first — without parsing any
                // existing line. This is a plain byte copy, so its cost tracks the file's
                // current size, not the number of lines it has ever held.
                let existingData = (try? Data(contentsOf: logFileURL)) ?? Data()
                var combinedData = Data()
                combinedData.append(data)
                combinedData.append(existingData)
                try combinedData.write(to: logFileURL, options: .atomic)

                // The expensive part — parsing every line's ISO8601 timestamp to enforce
                // retention/size limits — only needs to run occasionally, not on every write.
                if lastAutoPruneDate == nil
                    || date.timeIntervalSince(lastAutoPruneDate!) >= autoPruneInterval
                    || combinedData.count > maxBytes {
                    try pruneLocked(now: date)
                    lastAutoPruneDate = date
                }
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

        // `write()` always prepends new lines, so the file is already newest-first — no need
        // to re-sort it here. Re-sorting used to re-parse every line's ISO8601 timestamp
        // O(n log n) times (twice per comparison, with no memoization), which was the actual
        // cost behind AutoVolume.log writes getting slower the longer the app ran uninterrupted.
        let cutoff = now.addingTimeInterval(-retentionInterval)
        lines = lines.filter { line in
            guard let date = datePrefix(from: line) else { return true }
            return date >= cutoff
        }

        var prunedData = Data(lines.joined(separator: "\n").utf8)
        if !lines.isEmpty {
            prunedData.append(0x0A)
        }
        if prunedData.count > maxBytes {
            // Trim to 90% of the cap, not the cap itself: trimming to exactly `maxBytes` would
            // put the file right back over the limit after the very next line is appended,
            // forcing this same expensive parse-every-line prune to run on every single write
            // once the log reaches its size cap — reintroducing the bug this method exists to
            // avoid. Leaving headroom means dozens of writes happen before the next full prune.
            prunedData = newestPrefix(from: lines, maxBytes: maxBytes * 9 / 10)
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
