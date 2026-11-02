import Foundation
import Network
import AutoVolumeShared

/// Wraps `NWPathMonitor` to signal "the local network path changed" — Wi-Fi reconnected,
/// Ethernet plugged in, VPN connected/disconnected, woke from sleep onto a different network,
/// etc. A change that still leaves the path unsatisfied is worth a recheck too, so `status` is
/// part of what is compared, and so are the gateways: joining another network on the same
/// interface only changes those.
///
/// `NWPathMonitor` reports far more updates than there are real changes (AWDL / low-latency WLAN
/// interfaces flap constantly), so each update is reduced to a `NetworkPathSignature` and only a
/// differing signature is forwarded. Without this one machine logged ~29,000 "network-path-changed"
/// checks in a week, each of which also ran the full mount check and wrote log lines.
///
/// This is glue directly wrapping a system API and is intentionally not unit tested — see the
/// design doc's Testing Strategy section and this plan's Global Constraints.
final class NetworkPathWatcher {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.autovolume.agent.network-path-watcher")
    /// Only touched from `queue` (the monitor's serial handler queue).
    private var filter = NetworkPathChangeFilter()

    func start(onChange: @escaping () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let signature = NetworkPathSignature(
                status: String(describing: path.status),
                interfaces: path.availableInterfaces.map { .init(name: $0.name, type: String(describing: $0.type)) },
                gateways: path.gateways.map { String(describing: $0) }
            )
            guard self.filter.shouldTrigger(for: signature) else { return }
            onChange()
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
