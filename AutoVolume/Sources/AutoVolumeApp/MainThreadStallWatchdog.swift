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
    /// `MainThreadPingPong` is a class (not `Sendable`) but is internally synchronized with
    /// its own lock, so it is safe to call from both the background timer queue and the main
    /// queue — hence `nonisolated(unsafe)` rather than isolating it to the main actor along
    /// with the rest of this class. `AutoVolumeLogger` is `@unchecked Sendable` for the same
    /// reason, so it needs no such annotation.
    private let logger: AutoVolumeLogger
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
    ///
    /// Only that clock read happens on main. The actual log write is dispatched off to a
    /// background queue: `AutoVolumeLogger.write()` can itself take a while (it serializes
    /// against the stall-watchdog's own background writes and any other process logging to
    /// the same file via `flock`), and running it synchronously here was itself a source of
    /// main-thread stalls — logging that the main thread had recovered was, ironically,
    /// blocking it again.
    private nonisolated func pong() {
        guard let recovery = pingPong.recordPong() else { return }
        let durationMs = recovery.durationMs
        let logger = logger
        DispatchQueue.global(qos: .utility).async {
            logger.warning("Main thread recovered after \(durationMs)ms")
        }
    }
}
