import Foundation

public final class NTFSRemountDebouncer {
    private let cooldown: TimeInterval
    private var lastProcessed: [String: Date] = [:]
    private let lock = NSLock()

    public init(cooldown: TimeInterval = 30) {
        self.cooldown = cooldown
    }

    public func shouldProcess(bsdName: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastProcessed[bsdName] else { return true }
        return now.timeIntervalSince(last) > cooldown
    }

    public func markProcessed(bsdName: String, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        lastProcessed[bsdName] = date
    }
}
