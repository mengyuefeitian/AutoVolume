import Foundation

public struct NTFSMountPlanner {
    private let ntfs3gPath: String

    public init(ntfs3gPath: String) {
        self.ntfs3gPath = ntfs3gPath
    }

    public func unmountReadOnlyPlan(mountPoint: String) -> CommandPlan {
        CommandPlan(executable: "/usr/sbin/diskutil", arguments: ["unmount", mountPoint])
    }

    /// `volumeName` becomes `-o volname=`, so the mount is labeled with the disk's actual name
    /// instead of ntfs-3g/FUSE-T's fallback (the mount point's last path component) — see the
    /// doc comment on `NTFSHelperRequest.volumeName` for why that fallback isn't safe to rely on.
    /// `ntfs-3g`'s `-o volname` value is passed through to the FUSE/NFS-loopback layer as-is; it
    /// isn't shell-interpreted, so no escaping is needed here (matches how `devicePath` and
    /// `mountPoint` are already passed as separate `CommandPlan` arguments, not through a shell).
    ///
    /// `removeHiberfile` becomes `-o remove_hiberfile`, discarding a Windows hibernation file
    /// that's blocking a read-write mount (see `NTFSMountFailureClassifier` for how the caller
    /// decides this is needed). Defaults to `false` for the normal first attempt; the privileged
    /// helper retries with `true` only after the first attempt fails with the documented
    /// hibernation exit code.
    public func mountReadWritePlan(devicePath: String, mountPoint: String, volumeName: String?, removeHiberfile: Bool = false) -> CommandPlan {
        var arguments = [devicePath, mountPoint, "-olocal", "-oallow_other", "-oauto_xattr", "-onosuid", "-onoexec"]
        if removeHiberfile {
            arguments.append("-oremove_hiberfile")
        }
        // libfuse's `-o` parser splits on commas to separate multiple options within one `-o`
        // argument, with no escape syntax — a comma inside the value itself would be misread as
        // the start of a new (bogus) option. This argument is passed as its own argv element
        // (not through a shell), so nothing else needs escaping; only the comma is unsafe here.
        if let volumeName, !volumeName.isEmpty {
            let sanitized = volumeName.replacingOccurrences(of: ",", with: "_")
            arguments.append("-ovolname=\(sanitized)")
        }
        return CommandPlan(executable: ntfs3gPath, arguments: arguments)
    }
}
