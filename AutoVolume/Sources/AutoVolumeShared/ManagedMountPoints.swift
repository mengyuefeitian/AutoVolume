import Foundation

/// Pure computation of the real, live filesystem mount points AutoVolume manages, given the
/// current volume list. Used by `MountedVolumeWatcher` (in the AutoVolumeAgent target) to
/// decide whether an OS unmount notification is about one of our volumes.
///
/// Deliberately reuses `MountPlanner.unmountTarget(for:mountTable:)` rather than
/// `config.mountPoint` directly: for an SMB share with a subpath, the volume is actually
/// mounted at a `.AutoVolumeBacking/<uuid>` backing directory and `config.mountPoint` is just
/// a symlink into it (see `MountExposure.expose`), so comparing against `config.mountPoint`
/// would silently never match and real-time unmount detection would never fire for that
/// volume. For WebDAV/AFP/NFS, the real live mount point can only be resolved via the system
/// mount table, so `mountTable` is injectable — letting callers (and tests) substitute a fake
/// mount table instead of shelling out to the real `/sbin/mount`.
public enum ManagedMountPoints {
    public static func paths(for configs: [VolumeConfig], planner: MountPlanner = MountPlanner(), mountTable: SystemMountTable = SystemMountTable()) -> Set<String> {
        Set(configs.filter { $0.isEnabled }.map { planner.unmountTarget(for: $0, mountTable: mountTable) })
    }
}
