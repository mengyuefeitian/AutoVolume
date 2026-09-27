import Foundation

/// Wraps the system's screen-unlock notification to signal "the user just unlocked this Mac"
/// — a proxy for "this machine may have just moved onto a different network" (closed the lid
/// on one Wi-Fi, opened it on another) that `NetworkPathWatcher` alone can miss if the network
/// interface itself didn't visibly change state while locked. Triggers an immediate recheck
/// instead of waiting for the next scheduled tick.
///
/// `com.apple.screenIsUnlocked` is an undocumented but long-stable distributed notification
/// (not part of any public framework API) that macOS posts when the lock screen/screensaver is
/// dismissed — the standard mechanism menu-bar utilities use for this, since there is no public
/// `NSWorkspace` notification for "screen unlocked" specifically (`sessionDidBecomeActive` is
/// for fast user switching, not lock/unlock).
///
/// This is glue directly wrapping a system notification and is intentionally not unit tested —
/// see the design doc's Testing Strategy section and this plan's Global Constraints for the
/// same reasoning applied to `NetworkPathWatcher`/`ServerReachabilityWatcher`/`MountedVolumeWatcher`.
final class ScreenUnlockWatcher {
    private var observer: NSObjectProtocol?

    func start(onUnlock: @escaping () -> Void) {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: nil
        ) { _ in
            onUnlock()
        }
    }

    func stop() {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
}
