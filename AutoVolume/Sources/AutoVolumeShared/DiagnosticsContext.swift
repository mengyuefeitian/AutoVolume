import Foundation

/// Logs the elapsed time of named phases within a single operation (for example, a
/// WebDAV mount), so a stall or failure can be pinned to a specific step from the log
/// alone. Not thread-safe by itself — callers should confine a given instance to one
/// call path, matching how `AppViewModel`'s mount flow uses it today.
public final class PhaseTimer {
    private let operation: String
    private let logger: AutoVolumeLogger
    private let start: UInt64
    private var lastMark: UInt64

    public init(operation: String, logger: AutoVolumeLogger = .shared) {
        self.operation = operation
        self.logger = logger
        self.start = DispatchTime.now().uptimeNanoseconds
        self.lastMark = start
    }

    public func mark(_ phase: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        let sincePrevious = millis(from: lastMark, to: now)
        let sinceStart = millis(from: start, to: now)
        lastMark = now
        logger.info("\(operation) phase=\(phase) ms=\(sincePrevious) total_ms=\(sinceStart)")
    }

    public func finish(result: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        let sinceStart = millis(from: start, to: now)
        logger.info("\(operation) finished result=\(result) total_ms=\(sinceStart)")
    }

    private func millis(from: UInt64, to: UInt64) -> UInt64 {
        (to - from) / 1_000_000
    }
}

/// Tracks the name of the operation currently in flight on the main thread (for example
/// "webdav-mount home"), so anything that observes a problem independently of that
/// operation — most notably `MainThreadStallWatchdog` — can report what was running when
/// it happened. Thread-safe: `begin`/`end` are called from the operation's own thread,
/// `current` is read from the watchdog's background timer thread.
public final class DiagnosticsContext {
    public static let shared = DiagnosticsContext()

    private let lock = NSLock()
    private var operation: String?

    public init() {}

    public func begin(_ operation: String) {
        lock.lock()
        defer { lock.unlock() }
        self.operation = operation
    }

    public func end() {
        lock.lock()
        defer { lock.unlock() }
        self.operation = nil
    }

    public var current: String? {
        lock.lock()
        defer { lock.unlock() }
        return operation
    }
}
