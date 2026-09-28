import Foundation

/// Generic status for any OS permission this app depends on. Deliberately not specific to Full
/// Disk Access: a future permission requirement should be able to reuse this same shape and the
/// same Settings UI treatment (status icon + fix-it button) rather than inventing its own.
public enum PermissionStatus: Equatable {
    case granted
    case denied(message: String)
    /// The component that would need the permission (here, the privileged helper) hasn't been
    /// installed or started yet, so there's nothing to check yet — distinct from `.denied`
    /// because there's no fix-it button to offer until it exists.
    case notInstalled
}

/// Checks whether `NTFSPrivilegedHelper` — not this process — has Full Disk Access, by asking
/// the running daemon to probe it directly (see `checkFullDiskAccess()` in
/// `NTFSPrivilegedHelper/main.swift`). TCC grants and denies per-process, and it's the daemon
/// that opens raw NTFS disk devices, so checking from the app's own process would test the
/// wrong process entirely — exactly the confusion that made this permission so hard to
/// diagnose the first time.
public struct FullDiskAccessChecker {
    /// Deep-links straight to the Full Disk Access pane, so the Settings UI's fix-it button can
    /// take the user directly there instead of leaving them to find it under Privacy & Security.
    public static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    private let helperClient: NTFSHelperClientProtocol

    public init(helperClient: NTFSHelperClientProtocol = NTFSHelperClient()) {
        self.helperClient = helperClient
    }

    public func check() -> PermissionStatus {
        let response = helperClient.send(.checkFullDiskAccess())
        if response.success {
            return .granted
        }
        if response.message.contains("could not connect") || response.message.contains("no response") {
            return .notInstalled
        }
        return .denied(message: response.message)
    }
}
