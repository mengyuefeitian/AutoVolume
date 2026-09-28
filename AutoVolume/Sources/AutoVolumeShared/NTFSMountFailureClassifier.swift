import Foundation

/// Classifies an `ntfs-3g` mount attempt's exit code, so `NTFSPrivilegedHelper` (untested
/// glue, since it's a standalone executable) can decide whether to retry with
/// `-o remove_hiberfile` without embedding that decision inline where it can't be unit tested.
///
/// Exit code 14 is `NTFS_VOLUME_HIBERNATED` per `ntfs-3g.probe(8)`: the volume was left by
/// Windows in a hibernated/Fast-Startup state (`hiberfil.sys` present), which ntfs-3g refuses
/// to mount read-write to avoid corrupting a session Windows still considers "resumable". This
/// is extremely common in practice — Fast Startup has been the Windows default since Windows 8
/// — and previously required the user to boot back into Windows and shut down cleanly. Matching
/// on the documented exit code (not a substring of ntfs-3g's English stderr text) is what makes
/// this classification robust across ntfs-3g versions and independent of message wording.
public enum NTFSMountFailureReason: Equatable {
    case hibernated
    case other
}

public enum NTFSMountFailureClassifier {
    public static let hibernatedExitCode: Int32 = 14

    public static func classify(exitCode: Int32) -> NTFSMountFailureReason {
        exitCode == hibernatedExitCode ? .hibernated : .other
    }
}
