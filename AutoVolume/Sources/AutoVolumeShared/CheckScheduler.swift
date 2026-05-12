import Foundation

public struct CheckScheduler {
    private var lastCheckedAt: [UUID: Date] = [:]

    public init() {}

    public mutating func markChecked(volumeID: UUID, at date: Date) {
        lastCheckedAt[volumeID] = date
    }

    public func isDue(volumeID: UUID, interval: TimeInterval, now: Date) -> Bool {
        guard let lastChecked = lastCheckedAt[volumeID] else { return true }
        return now.timeIntervalSince(lastChecked) >= interval
    }
}
