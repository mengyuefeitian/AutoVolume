import Foundation

public struct NTFSMountPlanner {
    private let ntfs3gPath: String

    public init(ntfs3gPath: String) {
        self.ntfs3gPath = ntfs3gPath
    }

    public func unmountReadOnlyPlan(mountPoint: String) -> CommandPlan {
        CommandPlan(executable: "/usr/sbin/diskutil", arguments: ["unmount", mountPoint])
    }

    public func mountReadWritePlan(devicePath: String, mountPoint: String) -> CommandPlan {
        CommandPlan(
            executable: ntfs3gPath,
            arguments: [devicePath, mountPoint, "-olocal", "-oallow_other", "-oauto_xattr"]
        )
    }
}
