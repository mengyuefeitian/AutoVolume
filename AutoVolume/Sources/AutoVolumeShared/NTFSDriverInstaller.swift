import Foundation

public struct NTFSDriverInstaller {
    private let fileManager: FileManager
    private let fuseTMarkerPath: String

    public init(fileManager: FileManager = .default, fuseTMarkerPath: String = "/Library/Application Support/fuse-t/uninstall.sh") {
        self.fileManager = fileManager
        self.fuseTMarkerPath = fuseTMarkerPath
    }

    public func isFUSETInstalled() -> Bool {
        fileManager.fileExists(atPath: fuseTMarkerPath)
    }

    public func isHelperInstalled() -> Bool {
        fileManager.fileExists(atPath: NTFSHelperSocket.daemonPlistInstallPath)
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
        bundledNewsyslogConfPath: String? = nil
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
        let shellCommand = """
        set -e
        installer -pkg '\(shellEscaped(bundledInstallerPkgPath))' -target /
        mkdir -p '\(shellEscaped(driverDir))'
        cp '\(shellEscaped(bundledNTFS3GPath))' '\(shellEscaped(NTFSDriverPaths.ntfs3gExecutablePath))'
        cp '\(shellEscaped(bundledNTFS3GDylibPath))' '\(shellEscaped(NTFSDriverPaths.ntfs3gDylibPath))'
        chown root:wheel '\(shellEscaped(NTFSDriverPaths.ntfs3gExecutablePath))'
        chmod 755 '\(shellEscaped(NTFSDriverPaths.ntfs3gExecutablePath))'
        chown root:wheel '\(shellEscaped(NTFSDriverPaths.ntfs3gDylibPath))'
        chmod 644 '\(shellEscaped(NTFSDriverPaths.ntfs3gDylibPath))'
        cp '\(shellEscaped(bundledSharedDylibPath))' '\(shellEscaped(NTFSDriverPaths.sharedLibraryPath))'
        chown root:wheel '\(shellEscaped(NTFSDriverPaths.sharedLibraryPath))'
        chmod 644 '\(shellEscaped(NTFSDriverPaths.sharedLibraryPath))'
        cp '\(shellEscaped(bundledHelperExecutablePath))' '\(shellEscaped(NTFSHelperSocket.helperInstallPath))'
        chown root:wheel '\(shellEscaped(NTFSHelperSocket.helperInstallPath))'
        chmod 544 '\(shellEscaped(NTFSHelperSocket.helperInstallPath))'
        cp '\(shellEscaped(bundledDaemonPlistPath))' '\(shellEscaped(NTFSHelperSocket.daemonPlistInstallPath))'
        chown root:wheel '\(shellEscaped(NTFSHelperSocket.daemonPlistInstallPath))'
        chmod 644 '\(shellEscaped(NTFSHelperSocket.daemonPlistInstallPath))'\(newsyslogStep)
        launchctl bootout system '\(shellEscaped(NTFSHelperSocket.daemonPlistInstallPath))' 2>/dev/null || true
        launchctl bootstrap system '\(shellEscaped(NTFSHelperSocket.daemonPlistInstallPath))'
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
}
