import Foundation
import AutoVolumeShared

/// Detects when the main thread stops pumping its run loop for longer than
/// `thresholdMs` — the signature of the macOS 15.8 WebDAV mount stall this task exists
/// to diagnose — and logs it along with whatever `DiagnosticsContext` says was running
/// at the time.
///
/// The actual ping/pong bookkeeping lives in `MainThreadPingPong` (`AutoVolumeShared`),
/// which is unit tested directly with a manual clock. This type is a thin wrapper that
/// wires that state machine to a real `DispatchSourceTimer` (background queue) and
/// `DispatchQueue.main`.
@MainActor
final class MainThreadStallWatchdog {
    /// `AutoVolumeLogger` and `MainThreadPingPong` are classes (not `Sendable`), but both
    /// are internally synchronized with their own locks, so it is safe to call them from
    /// both the background timer queue and the main queue — hence `nonisolated(unsafe)`
    /// rather than isolating them to the main actor along with the rest of this class.
    private nonisolated(unsafe) let logger: AutoVolumeLogger
    private nonisolated(unsafe) let pingPong: MainThreadPingPong
    private nonisolated(unsafe) var timer: DispatchSourceTimer?

    init(thresholdMs: Int = 400, logger: AutoVolumeLogger = .shared) {
        self.logger = logger
        self.pingPong = MainThreadPingPong(thresholdMs: thresholdMs)
    }

    func start() {
        let queue = DispatchQueue(label: "com.autovolume.stall-watchdog", qos: .utility)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        source.resume()
        timer = source
    }

    private nonisolated func tick() {
        let result = pingPong.tick()
        if let stall = result.stall {
            let operation = DiagnosticsContext.shared.current ?? "idle"
            logger.warning("Main thread stalled \u{2265}\(stall.gapMs)ms during \(operation)")
        }
        guard result.shouldSendPing else { return }
        DispatchQueue.main.async { [weak self] in
            self?.pong()
        }
    }

    /// Runs on the main queue at the moment the dispatched ping block is actually
    /// serviced — this is the "pong". `MainThreadPingPong.recordPong()` stamps its own
    /// clock reading right now, so the recovery duration reflects how long the main
    /// queue actually took to get here, not how long ago the background timer ticked.
    private nonisolated func pong() {
        if let recovery = pingPong.recordPong() {
            logger.warning("Main thread recovered after \(recovery.durationMs)ms")
        }
    }
}
