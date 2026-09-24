import Foundation

public struct NTFSDriverInstaller {
    private let fileManager: FileManager
    private let fuseTMarkerPath: String
    private let versionStampPath: String
    private let daemonPlistPath: String

    public init(
        fileManager: FileManager = .default,
        fuseTMarkerPath: String = "/Library/Application Support/fuse-t/uninstall.sh",
        versionStampPath: String = NTFSDriverPaths.versionStampPath,
        daemonPlistPath: String = NTFSHelperSocket.daemonPlistInstallPath
    ) {
        self.fileManager = fileManager
        self.fuseTMarkerPath = fuseTMarkerPath
        self.versionStampPath = versionStampPath
        self.daemonPlistPath = daemonPlistPath
    }

    public func isFUSETInstalled() -> Bool {
        fileManager.fileExists(atPath: fuseTMarkerPath)
    }

    public func isHelperInstalled() -> Bool {
        fileManager.fileExists(atPath: daemonPlistPath)
    }

    /// True only when the daemon plist is present *and* the on-disk build stamp matches
    /// `expectedBuild` — i.e. the currently-running app's bundled helper is the one actually
    /// installed under `/Library/PrivilegedHelperTools`. A Sparkle update replaces the app
    /// bundle but leaves that root-owned copy in place, so a stale stamp (or one missing
    /// entirely, for installs predating this check) must be treated as "not installed" to
    /// trigger a reinstall.
    public func isHelperInstalled(expectedBuild: String) -> Bool {
        guard isHelperInstalled() else { return false }
        guard let stampContents = try? String(contentsOfFile: versionStampPath, encoding: .utf8) else { return false }
        return stampContents.trimmingCharacters(in: .whitespacesAndNewlines) == expectedBuild
    }

    public func isFullyInstalled() -> Bool {
        isFUSETInstalled() && isHelperInstalled()
    }

    public func installPlan(
        bundledInstallerPkgPath: String,
        bundledHelperExecutablePath: String,
        bundledDaemonPlistPath: String,
        bundledNTFS3GPath: String,
        bundledNTFS3GDylibPath: String,
        bundledSharedDylibPath: String,
        bundledNewsyslogConfPath: String? = nil,
        bundleBuild: String = "0"
    ) -> CommandPlan {
        let driverDir = NTFSDriverPaths.installDirectory
        let newsyslogStep: String
        if let bundledNewsyslogConfPath {
            newsyslogStep = """

            mkdir -p '\(shellEscaped("/etc/newsyslog.d"))'
            cp '\(shellEscaped(bundledNewsyslogConfPath))' '\(shellEscaped(NTFSHelperSocket.newsyslogConfInstallPath))'
            chown root:wheel '\(shellEscaped(NTFSHelperSocket.newsyslogConfInstallPath))'
            chmod 644 '\(shellEscaped(NTFSHelperSocket.newsyslogConfInstallPath))'
            """
        } else {
            newsyslogStep = ""
        }
        // Reinstall is now the normal path after every app update (not just a first-time
        // install), so this must never modify a live, signed Mach-O in place: the KeepAlive
        // LaunchDaemon may still be running against the old binary, and a mounted volume's
        // ntfs-3g can have the old dylib mapped. Overwriting bytes under a running/mapped
        // binary invalidates the kernel's code-signature cache and can SIGKILL the process or
        // produce an "invalid signature" mount failure.
        //
        // Order matters:
        //  1. bootout the daemon FIRST, before touching any file on disk.
        //  2. only run the FUSE-T pkg installer if FUSE-T isn't already present (guarded by
        //     its own uninstall-marker file) — the installer itself is not safe to force on
        //     every reinstall.
        //  3. write every binary/dylib/plist to a sibling `.new` path, chown/chmod that new
        //     inode, then atomically `mv -f` it onto the real destination. This replaces the
        //     directory entry instead of the bytes an already-open file descriptor points to.
        //  4. bootstrap the daemon against the newly-renamed files.
        //  5. write the build stamp LAST, only after bootstrap has actually succeeded — `set
        //     -e` aborts the whole script on any earlier failure, so the stamp only lands when
        //     every step before it (including bootstrap) succeeded.
        let shellCommand = """
        set -e
        launchctl bootout system '\(shellEscaped(NTFSHelperSocket.daemonPlistInstallPath))' 2>/dev/null || true
        [ -f '\(shellEscaped(fuseTMarkerPath))' ] || installer -pkg '\(shellEscaped(bundledInstallerPkgPath))' -target /
        mkdir -p '\(shellEscaped(driverDir))'
        \(atomicInstallStep(source: bundledNTFS3GPath, destination: NTFSDriverPaths.ntfs3gExecutablePath, mode: "755"))
        \(atomicInstallStep(source: bundledNTFS3GDylibPath, destination: NTFSDriverPaths.ntfs3gDylibPath, mode: "644"))
        \(atomicInstallStep(source: bundledSharedDylibPath, destination: NTFSDriverPaths.sharedLibraryPath, mode: "644"))
        \(atomicInstallStep(source: bundledHelperExecutablePath, destination: NTFSHelperSocket.helperInstallPath, mode: "544"))
        \(atomicInstallStep(source: bundledDaemonPlistPath, destination: NTFSHelperSocket.daemonPlistInstallPath, mode: "644"))\(newsyslogStep)
        launchctl bootstrap system '\(shellEscaped(NTFSHelperSocket.daemonPlistInstallPath))'
        printf '%s' '\(shellEscaped(bundleBuild))' > '\(shellEscaped(NTFSDriverPaths.versionStampPath))'
        chmod 644 '\(shellEscaped(NTFSDriverPaths.versionStampPath))'
        """
        let escapedShellCommand = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return CommandPlan(
            executable: "/usr/bin/osascript",
            arguments: ["-e", "do shell script \"\(escapedShellCommand)\" with administrator privileges"]
        )
    }

    /// Removes the AutoVolume-specific NTFS artifacts installed by `installPlan`: the
    /// LaunchDaemon (bootout + plist), the privileged helper binary, the driver install
    /// directory (ntfs-3g, its dylib, and the shared dylib copy), and the newsyslog.d conf.
    /// FUSE-T itself is a separate, user-installed product via its own pkg and is
    /// intentionally left alone. Each step tolerates a partial install via `|| true`.
    public func uninstallPlan() -> CommandPlan {
        let shellCommand = """
        launchctl bootout system '\(shellEscaped(NTFSHelperSocket.daemonPlistInstallPath))' 2>/dev/null || true
        rm -f '\(shellEscaped(NTFSHelperSocket.daemonPlistInstallPath))'
        rm -f '\(shellEscaped(NTFSHelperSocket.helperInstallPath))'
        rm -rf '\(shellEscaped(NTFSDriverPaths.installDirectory))'
        rm -f /etc/newsyslog.d/com.autovolume.ntfshelper.conf
        """
        let escapedShellCommand = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return CommandPlan(
            executable: "/usr/bin/osascript",
            arguments: ["-e", "do shell script \"\(escapedShellCommand)\" with administrator privileges"]
        )
    }

    private func shellEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }

    /// Copies `source` into a sibling `<destination>.new` path, chowns/chmods that new inode,
    /// then atomically renames it onto `destination` via `mv -f`. Never writes through the
    /// existing `destination` path directly — see the ordering comment in `installPlan`.
    private func atomicInstallStep(source: String, destination: String, mode: String) -> String {
        let escapedDestination = shellEscaped(destination)
        let stagingPath = "\(escapedDestination).new"
        return """
        cp '\(shellEscaped(source))' '\(stagingPath)'
        chown root:wheel '\(stagingPath)'
        chmod \(mode) '\(stagingPath)'
        mv -f '\(stagingPath)' '\(escapedDestination)'
        """
    }
}
