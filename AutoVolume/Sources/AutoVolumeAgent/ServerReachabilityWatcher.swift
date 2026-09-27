import Foundation
import SystemConfiguration

/// Wraps `SCNetworkReachability`, one ref per distinct server hostname, to signal "this
/// specific server's reachability just changed" — covers the case where the local network
/// never changed but the remote host did (NAS rebooted, came back online), so
/// `NetworkPathWatcher` alone would never fire.
///
/// This is glue directly wrapping a system API and is intentionally not unit tested — see the
/// design doc's Testing Strategy section and this plan's Global Constraints. The set-difference
/// bookkeeping in `sync` is simple enough (plain `Set` operations) not to need its own
/// extracted, tested helper.
final class ServerReachabilityWatcher {
    /// Bundles a host's `SCNetworkReachability` ref with the host string, so the C callback
    /// (which only receives the ref and an opaque `info` pointer) can report back which host
    /// changed. `watcher` is `weak` to avoid a retain cycle: this object's lifetime is owned by
    /// `registrations`, which is owned by `ServerReachabilityWatcher`.
    ///
    /// `onChange` also lives here rather than being captured directly by the C callback closure:
    /// a `SCNetworkReachabilityCallBack` is a `@convention(c)` function pointer, and Swift does
    /// not allow forming a C function pointer from a closure that captures any context. Routing
    /// through the same `info` pointer that already carries `host` and `watcher` keeps the
    /// callback capture-free while still reaching the right per-registration closure.
    private final class Registration {
        let host: String
        let ref: SCNetworkReachability
        let onChange: (String, Bool) -> Void
        weak var watcher: ServerReachabilityWatcher?
        init(host: String, ref: SCNetworkReachability, onChange: @escaping (String, Bool) -> Void, watcher: ServerReachabilityWatcher) {
            self.host = host
            self.ref = ref
            self.onChange = onChange
            self.watcher = watcher
        }
    }

    private var registrations: [String: Registration] = [:]
    private let queue = DispatchQueue(label: "com.autovolume.agent.server-reachability-watcher")

    /// Adds reachability monitoring for any host in `hosts` not already watched, and removes
    /// monitoring for any host no longer in `hosts` (its volume was deleted or disabled). Safe
    /// to call repeatedly with the same or a changed set — cheap when nothing changed. `onChange`
    /// is captured fresh into each newly-created `Registration` (the closure captures the current
    /// `checkVolumesNow`, which doesn't change, so every call passes an equivalent closure in
    /// practice); already-registered hosts keep whichever `onChange` they were created with.
    func sync(hosts: Set<String>, onChange: @escaping (String, Bool) -> Void) {
        let currentHosts = Set(registrations.keys)

        for host in currentHosts.subtracting(hosts) {
            if let registration = registrations.removeValue(forKey: host) {
                SCNetworkReachabilitySetCallback(registration.ref, nil, nil)
                SCNetworkReachabilitySetDispatchQueue(registration.ref, nil)
            }
        }

        for host in hosts.subtracting(currentHosts) {
            guard let ref = SCNetworkReachabilityCreateWithName(nil, host) else { continue }
            let registration = Registration(host: host, ref: ref, onChange: onChange, watcher: self)
            registrations[host] = registration

            let info = Unmanaged.passUnretained(registration).toOpaque()
            var context = SCNetworkReachabilityContext(version: 0, info: info, retain: nil, release: nil, copyDescription: nil)
            let callback: SCNetworkReachabilityCallBack = { _, flags, info in
                guard let info else { return }
                let registration = Unmanaged<Registration>.fromOpaque(info).takeUnretainedValue()
                registration.watcher?.handleFlagsChanged(flags: flags, host: registration.host, onChange: registration.onChange)
            }
            guard SCNetworkReachabilitySetCallback(ref, callback, &context) else { continue }
            SCNetworkReachabilitySetDispatchQueue(ref, queue)

            // The callback above only fires on a *change*. Read the current flags once up
            // front so a host that's already unreachable at the moment it's first registered
            // (e.g. a volume added while the NAS happens to be down) is reflected immediately
            // instead of silently waiting for the next transition.
            var initialFlags = SCNetworkReachabilityFlags()
            if SCNetworkReachabilityGetFlags(ref, &initialFlags) {
                handleFlagsChanged(flags: initialFlags, host: host, onChange: onChange)
            }
        }
    }

    private func handleFlagsChanged(flags: SCNetworkReachabilityFlags, host: String, onChange: (String, Bool) -> Void) {
        let isReachable = flags.contains(.reachable) && !flags.contains(.connectionRequired)
        onChange(host, isReachable)
    }
}
