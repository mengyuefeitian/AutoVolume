import Foundation

/// Classifies an `ntfs-3g` mount attempt's exit code and stderr, so `NTFSPrivilegedHelper`
/// (untested glue, since it's a standalone executable) can decide whether to retry with
/// `-o remove_hiberfile` without embedding that decision inline where it can't be unit tested.
///
/// Exit code 14 is `NTFS_VOLUME_HIBERNATED` per `ntfs-3g.probe(8)` — but exit codes 13/14 are
/// ntfs-3g's *generic* error-mapping buckets, not solely dedicated to genuine hibernation
/// detection: they're also what a plain failure to even `open(2)` the device node (e.g. `EPERM`)
/// gets mapped to. A run observed in the field printed `Error opening '/dev/diskN': Operation
/// not permitted` as stderr's first line alongside exit code 14 — that's ntfs-3g failing before
/// it ever read the volume's `$Volume` metadata to check the actual hibernation flag, so treating
/// it as "hibernated" would be a false positive: `-o remove_hiberfile` cannot fix a device that
/// never opened, and reporting a hibernation-recovery notice to the user would be a lie about
/// what actually happened. Genuine `NTFS_VOLUME_HIBERNATED` only occurs after ntfs-3g has
/// successfully opened and read the volume, so this additionally requires stderr to NOT start
/// with ntfs-3g's "Error opening" prefix before classifying as `.hibernated`.
public enum NTFSMountFailureReason: Equatable {
    case hibernated
    case other
}

public enum NTFSMountFailureClassifier {
    public static let hibernatedExitCode: Int32 = 14

    public static func classify(exitCode: Int32, stderr: String) -> NTFSMountFailureReason {
        guard exitCode == hibernatedExitCode else { return .other }
        guard !stderr.hasPrefix("Error opening") else { return .other }
        return .hibernated
    }
}
