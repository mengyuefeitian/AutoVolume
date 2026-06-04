import Foundation
import Darwin

public final class AutoVolumeLogger {
    public static let shared = AutoVolumeLogger()

    public let logFileURL: URL
    public let retentionInterval: TimeInterval
    public let maxBytes: Int

    private let lock = NSLock()
    private let calendar = ISO8601DateFormatter()

    public init(
        directory: URL? = nil,
        retentionInterval: TimeInterval = 24 * 60 * 60,
        maxBytes: Int = 10 * 1024 * 1024
    ) {
        let baseDirectory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("AutoVolume", isDirectory: true)
        self.logFileURL = baseDirectory.appendingPathComponent("AutoVolume.log")
        self.retentionInterval = retentionInterval
        self.maxBytes = maxBytes
        calendar.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public var logDirectoryURL: URL {
        logFileURL.deletingLastPathComponent()
    }

    public func info(_ message: String) {
        write(level: "INFO", message: message)
    }

    public func warning(_ message: String) {
        write(level: "WARN", message: message)
    }

    public func error(_ message: String) {
        write(level: "ERROR", message: message)
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
        let lockURL = logDirectoryURL.appendingPathComponent(".AutoVolume.log.lock")
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
