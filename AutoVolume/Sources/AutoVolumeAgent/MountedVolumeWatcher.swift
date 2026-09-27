import Foundation
import AppKit

/// Wraps `NSWorkspace`'s unmount notification to signal "the OS just force-unmounted one of
/// our configured network volumes" — SMB in particular will sometimes unmount a
/// long-unresponsive share on its own, without AutoVolume having done anything. Filters to only
/// the mount points AutoVolume actually manages (via `managedMountPoints`, evaluated fresh on
/// every notification so it always reflects the current volume list) so ejecting an unrelated
/// USB drive doesn't trigger a recheck.
///
/// This is glue directly wrapping a system API and is intentionally not unit tested — see the
/// design doc's Testing Strategy section and this plan's Global Constraints. The filtering logic
/// it depends on (`ManagedMountPoints.paths`) is tested in Task 2.
final class MountedVolumeWatcher {
    private var observer: NSObjectProtocol?

    func start(managedMountPoints: @escaping () -> Set<String>, onUnmount: @escaping () -> Void) {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            guard managedMountPoints().contains(url.path) else { return }
            onUnmount()
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
