import Foundation

/// The ping/pong state machine behind `MainThreadStallWatchdog`, extracted so it can be
/// unit tested with a manually-controlled clock instead of real timers and dispatch
/// queues.
///
/// The design deliberately separates "the background timer ticked" from "the target
/// queue (e.g. main) is stalled": a tick only *sends* a fresh ping when none is already
/// outstanding, and only *reports* a stall when a ping has been outstanding longer than
/// the threshold. This means a long gap between ticks (App Nap, timer coalescing) is
/// harmless as long as the previous ping's pong already arrived — only a ping that is
/// actually stuck waiting for the target queue is ever reported.
///
/// Thread-safety: `tick()` is expected to be called from one thread (the background
/// timer queue) and `recordPong()` from another (e.g. the main queue) — all mutable
/// state is guarded by an internal lock.
public final class MainThreadPingPong {
    public struct Stall {
        public let gapMs: Int
    }

    public struct Recovery {
        public let durationMs: Int
    }

    public struct TickResult {
        /// True when no ping was outstanding, so the caller should send a fresh one
        /// (typically by dispatching a block onto the target queue that calls
        /// `recordPong()` when it runs).
        public let shouldSendPing: Bool
        /// Non-nil exactly once per stall: the first tick that observes an outstanding
        /// ping older than the threshold. Subsequent ticks return `nil` for the same
        /// stall until `recordPong()` clears it.
        public let stall: Stall?
    }

    private let thresholdMs: Int
    private let clock: () -> UInt64
    private let lock = NSLock()
    private var pingSentAtNanos: UInt64?
    private var hasReportedCurrentStall = false

    public init(thresholdMs: Int, clock: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.thresholdMs = thresholdMs
        self.clock = clock
    }

    public func tick() -> TickResult {
        lock.lock()
        defer { lock.unlock() }

        guard let sentAt = pingSentAtNanos else {
            pingSentAtNanos = clock()
            return TickResult(shouldSendPing: true, stall: nil)
        }

        let gapMs = Int((clock() &- sentAt) / 1_000_000)
        if gapMs > thresholdMs, !hasReportedCurrentStall {
            hasReportedCurrentStall = true
            return TickResult(shouldSendPing: false, stall: Stall(gapMs: gapMs))
        }
        return TickResult(shouldSendPing: false, stall: nil)
    }

    /// Call this from the target queue (e.g. main) at the moment the ping's dispatched
    /// block actually runs. Returns a `Recovery` only if that ping had previously been
    /// reported as a stall — a pong that arrives before the threshold is crossed is not
    /// a "recovery" because nothing was ever reported as stalled.
    @discardableResult
    public func recordPong() -> Recovery? {
        lock.lock()
        defer { lock.unlock() }

        guard let sentAt = pingSentAtNanos else { return nil }
        let wasStalled = hasReportedCurrentStall
        pingSentAtNanos = nil
        hasReportedCurrentStall = false

        guard wasStalled else { return nil }
        let durationMs = Int((clock() &- sentAt) / 1_000_000)
        return Recovery(durationMs: durationMs)
    }
}
