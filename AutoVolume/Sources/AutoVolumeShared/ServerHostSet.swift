import Foundation

/// Pure computation of which distinct server hostnames need real-time reachability
/// monitoring, given the current volume list. Used by `ServerReachabilityWatcher` (in the
/// AutoVolumeAgent target) to know which hosts to register `SCNetworkReachability` callbacks
/// for. Kept here, dependency-free, so it's unit testable without any system API glue.
public enum ServerHostSet {
    public static func hosts(for configs: [VolumeConfig]) -> Set<String> {
        let tester = ConnectivityTester()
        var hosts = Set<String>()
        for config in configs where config.isEnabled {
            let host = tester.hostOnly(config.server)
            guard !host.isEmpty else { continue }
            hosts.insert(host)
        }
        return hosts
    }
}
