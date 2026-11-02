import Foundation

/// Why a folder is a poor place to mount a network volume.
public enum MountPointIssue: Equatable {
    /// `/Volumes` belongs to the system: it clears entries it does not recognise at startup and a user
    /// cannot create folders there, which is how issue #2 ("couldn't be saved in the folder Volumes") arose.
    case systemVolumes
    /// Desktop, Documents, Downloads and iCloud Drive are covered by macOS privacy protection (the
    /// background agent may be refused or prompt) and iCloud Drive would try to sync the mounted files.
    case protectedFolder
    /// Inside another mounted volume: when the outer one drops, the inner one goes with it.
    case insideMount
    /// Not an absolute path (the agent would resolve it against its own working directory).
    case notAbsolute
}

public enum MountPointRules {
    private static let protectedHomeFolders = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"]

    /// Any folder in the home directory outside the cases above is equally good — `~/Volumes`,
    /// `~/mnt` and so on behave the same, because the mount is kept alive by the agent, not by the path.
    /// `mountedPaths` are the mount points currently in the system table.
    public static func issue(for path: String, homeDirectory: String, mountedPaths: [String]) -> MountPointIssue? {
        guard path.hasPrefix("/") else { return .notAbsolute }
        let target = normalized(path)
        if isInside(target, of: "/Volumes") { return .systemVolumes }
        let home = normalized(homeDirectory)
        for folder in protectedHomeFolders where isInside(target, of: home + "/" + folder) {
            return .protectedFolder
        }
        for mounted in mountedPaths.map(normalized) where mounted != target && isInside(target, of: mounted) {
            return .insideMount
        }
        return nil
    }

    private static func normalized(_ path: String) -> String {
        var value = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// `path` is `root` or something below it, compared by whole path components.
    private static func isInside(_ path: String, of root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }
}
