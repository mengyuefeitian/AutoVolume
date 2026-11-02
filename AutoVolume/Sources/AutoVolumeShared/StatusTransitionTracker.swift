import Foundation

/// Decides whether an observation about a volume is worth a log line: only the first one and
/// changes. The agent used to write "Agent check mounted for X" on every check — over 29,000 lines
/// (6.5MB) a week — which buried everything useful and made every log write slower.
public struct StatusTransitionTracker {
    private var lastStates: [UUID: String] = [:]

    public init() {}

    public mutating func shouldLog(volumeID: UUID, state: String) -> Bool {
        guard lastStates[volumeID] != state else { return false }
        lastStates[volumeID] = state
        return true
    }
}
