import Foundation
import Network

/// Wraps `NWPathMonitor` to signal "the local network path changed" — Wi-Fi reconnected,
/// Ethernet plugged in, VPN connected/disconnected, woke from sleep onto a different network,
/// etc. Deliberately does not inspect `NWPath.status`: even a change that still leaves the
/// path unsatisfied is worth an immediate recheck, and an extra recheck against an
/// already-healthy volume is cheap (a local `isMounted` check, no network I/O for volumes that
/// are already fine).
///
/// This is glue directly wrapping a system API and is intentionally not unit tested — see the
/// design doc's Testing Strategy section and this plan's Global Constraints.
final class NetworkPathWatcher {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.autovolume.agent.network-path-watcher")

    func start(onChange: @escaping () -> Void) {
        monitor.pathUpdateHandler = { _ in
            onChange()
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
