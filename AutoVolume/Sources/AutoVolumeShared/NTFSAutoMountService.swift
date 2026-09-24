import Foundation

public struct NTFSBundledInstallerPaths {
    public var fuseTInstallerPkgPath: String
    public var helperExecutablePath: String
    public var daemonPlistPath: String
    public var ntfs3gPath: String
    public var ntfs3gDylibPath: String
    public var newsyslogConfPath: String
    public var sharedDylibPath: String
    /// The running app bundle's `CFBundleVersion`, used to detect a Sparkle update that
    /// replaced `/Applications/AutoVolume.app` without reinstalling the root-owned helper
    /// copy under `/Library/PrivilegedHelperTools`.
    public var bundleBuild: String

    public init(bundle: Bundle = .main) {
        let resourcesPath = bundle.resourcePath ?? "/Applications/AutoVolume.app/Contents/Resources"
        self.fuseTInstallerPkgPath = resourcesPath + "/NTFSDriver/fuse-t-installer.pkg"
        self.helperExecutablePath = resourcesPath + "/NTFSPrivilegedHelper"
        self.daemonPlistPath = resourcesPath + "/com.autovolume.ntfshelper.plist"
        self.ntfs3gPath = resourcesPath + "/NTFSDriver/ntfs-3g"
        self.ntfs3gDylibPath = resourcesPath + "/NTFSDriver/libntfs-3g.89.dylib"
        self.newsyslogConfPath = resourcesPath + "/com.autovolume.ntfshelper.newsyslog.conf"
        // The app bundle already places this at Contents/Frameworks (for the app/agent);
        // the installer copies this same file into the privileged driver directory so
        // NTFSPrivilegedHelper (running standalone as a LaunchDaemon) can load it too.
        self.sharedDylibPath = resourcesPath + "/../Frameworks/libAutoVolumeShared.dylib"
        self.bundleBuild = Self.resolveBundleBuild(resourcesPath: resourcesPath)
    }

    /// `bundle.resourcePath` (above) is not itself a fully-formed app bundle — the Agent
    /// process passes a `Bundle` rooted at `.../AutoVolume.app/Contents/Resources`, whose
    /// own `infoDictionary` is empty. The real `Info.plist` (with `CFBundleVersion`) lives
    /// two levels up, at `.../AutoVolume.app/Contents/Info.plist`, so resolve the `.app`
    /// bundle explicitly from the resources path: resources dir → Contents → .app.
    private static func resolveBundleBuild(resourcesPath: String) -> String {
        let appBundlePath = URL(fileURLWithPath: resourcesPath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        return (Bundle(path: appBundlePath)?.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }
}

public final class NTFSAutoMountService {
    public static let onboardingAlertID = UUID(uuidString: "00000000-0000-0000-0000-00000000AF01")!

    private let settingsStore: AppSettingsStore
    private let driverInstaller: NTFSDriverInstaller
    private let helperClient: NTFSHelperClientProtocol
    private let mountedVolumesStore: NTFSMountedVolumesStore
    private let commandRunner: CommandRunner
    private let alertStore: AlertStore
    private let debouncer: NTFSRemountDebouncer
    private let bundledInstallerPaths: NTFSBundledInstallerPaths
    private let logger: AutoVolumeLogger
    /// Once true, `installPlan` is never re-run for the remainder of this instance's
    /// lifetime (this is an in-memory, instance-scoped flag; it does not persist across
    /// Agent restarts — an accepted scoping tradeoff).
    private var hasAttemptedInstallThisSession = false
    /// Deterministic per-bsdName alert IDs for mount-failure alerts, so a failure on one
    /// device doesn't clobber the onboarding alert or another device's failure alert.
    private var mountFailureAlertIDs: [String: UUID] = [:]

    public init(
        settingsStore: AppSettingsStore = JSONAppSettingsStore(),
        driverInstaller: NTFSDriverInstaller = NTFSDriverInstaller(),
        helperClient: NTFSHelperClientProtocol = NTFSHelperClient(),
        mountedVolumesStore: NTFSMountedVolumesStore = NTFSMountedVolumesStore(),
        commandRunner: CommandRunner = ProcessCommandRunner(),
        alertStore: AlertStore = AlertStore(),
        debouncer: NTFSRemountDebouncer = NTFSRemountDebouncer(),
        bundledInstallerPaths: NTFSBundledInstallerPaths = NTFSBundledInstallerPaths(),
        logger: AutoVolumeLogger = .ntfs
    ) {
        self.settingsStore = settingsStore
        self.driverInstaller = driverInstaller
        self.helperClient = helperClient
        self.mountedVolumesStore = mountedVolumesStore
        self.commandRunner = commandRunner
        self.alertStore = alertStore
        self.debouncer = debouncer
        self.bundledInstallerPaths = bundledInstallerPaths
        self.logger = logger
    }

    public func handleDiskEligibleForReadWrite(
        bsdName: String,
        devicePath: String,
        volumeName: String,
        mountPoint: String,
        filesystemPersonality: String?,
        mountedFileSystemName: String?
    ) {
        guard NTFSDiskClassifier.isNTFSFileSystem(personality: filesystemPersonality) else { return }
        guard !NTFSDiskClassifier.isOwnedByOurDriver(mountedFileSystemName: mountedFileSystemName) else {
            logger.info("NTFS disk bsd=\(bsdName) kind=\(mountedFileSystemName ?? "unknown") name=\(volumeName) path=\(mountPoint) already owned by our driver, skipping")
            return
        }
        guard debouncer.shouldProcess(bsdName: bsdName) else {
            logger.info("NTFS disk bsd=\(bsdName) name=\(volumeName) debounced, skipping")
            return
        }
        debouncer.markProcessed(bsdName: bsdName)

        let settings = (try? settingsStore.load()) ?? AppSettings()
        guard settings.autoMountNTFSReadWrite else {
            logger.info("NTFS disk bsd=\(bsdName) name=\(volumeName) auto-mount setting disabled, recording onboarding alert")
            try? alertStore.record(
                volumeID: Self.onboardingAlertID,
                volumeName: volumeName,
                key: .alertNTFSOnboarding,
                args: [volumeName]
            )
            return
        }

        let wasFullyInstalled = driverInstaller.isFUSETInstalled()
            && driverInstaller.isHelperInstalled(expectedBuild: bundledInstallerPaths.bundleBuild)
        if !wasFullyInstalled {
            let stampMatches = driverInstaller.isHelperInstalled(expectedBuild: bundledInstallerPaths.bundleBuild)
            logger.info("NTFS driver not fully installed for bsd=\(bsdName) (fuseTInstalled=\(driverInstaller.isFUSETInstalled()) helperBuildMatches=\(stampMatches) expectedBuild=\(bundledInstallerPaths.bundleBuild)); reinstall required")
            guard !hasAttemptedInstallThisSession else {
                logger.info("NTFS install already attempted this session; skipping bsd=\(bsdName)")
                return
            }
            hasAttemptedInstallThisSession = true

            let plan = driverInstaller.installPlan(
                bundledInstallerPkgPath: bundledInstallerPaths.fuseTInstallerPkgPath,
                bundledHelperExecutablePath: bundledInstallerPaths.helperExecutablePath,
                bundledDaemonPlistPath: bundledInstallerPaths.daemonPlistPath,
                bundledNTFS3GPath: bundledInstallerPaths.ntfs3gPath,
                bundledNTFS3GDylibPath: bundledInstallerPaths.ntfs3gDylibPath,
                bundledSharedDylibPath: bundledInstallerPaths.sharedDylibPath,
                bundledNewsyslogConfPath: bundledInstallerPaths.newsyslogConfPath,
                bundleBuild: bundledInstallerPaths.bundleBuild
            )
            logger.info("NTFS driver install started for bsd=\(bsdName)")
            let installStart = DispatchTime.now().uptimeNanoseconds
            let installResult = try? commandRunner.run(plan)
            let installDurationMs = (DispatchTime.now().uptimeNanoseconds - installStart) / 1_000_000
            guard let installResult, installResult.exitCode == 0 else {
                let exitCode = installResult?.exitCode ?? -1
                let stderr = CommandResult.redacted(installResult?.stderr ?? "")
                logger.warning("NTFS driver install finished exitCode=\(exitCode) stderr=\(stderr) duration_ms=\(installDurationMs)")
                try? alertStore.record(
                    volumeID: Self.onboardingAlertID,
                    volumeName: volumeName,
                    key: .alertNTFSInstallFailed,
                    args: [volumeName]
                )
                return
            }
            logger.info("NTFS driver install finished exitCode=0 duration_ms=\(installDurationMs)")
        }

        logger.info("NTFS helper request sent: device=\(devicePath) -> mountPoint=\(mountPoint)")
        let responseStart = DispatchTime.now().uptimeNanoseconds
        var response = helperClient.send(NTFSHelperRequest(action: .mount, devicePath: devicePath, mountPoint: mountPoint))
        if !wasFullyInstalled, response.message.contains("could not connect") {
            // launchctl bootstrap returns once the job is loaded, not once the daemon has
            // created and is listening on its socket, so the very next connect attempt can
            // race the daemon's startup. Retry a few times with a short delay (bounded to
            // 2.5s total) before giving up.
            for _ in 0..<5 where response.message.contains("could not connect") {
                Thread.sleep(forTimeInterval: 0.5)
                response = helperClient.send(NTFSHelperRequest(action: .mount, devicePath: devicePath, mountPoint: mountPoint))
                if response.success { break }
            }
        }
        let responseDurationMs = (DispatchTime.now().uptimeNanoseconds - responseStart) / 1_000_000
        logger.info("NTFS helper response: \(response.success ? "success" : "failure") message=\(CommandResult.redacted(response.message)) duration_ms=\(responseDurationMs)")

        guard response.success else {
            try? alertStore.record(
                volumeID: mountFailureAlertID(for: bsdName),
                volumeName: volumeName,
                key: .alertNTFSMountFailed,
                args: [volumeName, response.message]
            )
            _ = try? commandRunner.run(CommandPlan(executable: "/usr/sbin/diskutil", arguments: ["mount", bsdName]))
            return
        }

        try? mountedVolumesStore.add(NTFSVolume(bsdName: bsdName, volumeName: volumeName, devicePath: devicePath, mountPoint: mountPoint, mountedAt: Date()))
        logger.info("NTFS volume recorded bsd=\(bsdName) name=\(volumeName) path=\(mountPoint)")
        try? alertStore.resolve(volumeID: Self.onboardingAlertID)
    }

    public func handleDiskDisappeared(bsdName: String) {
        if let volume = (try? mountedVolumesStore.load())?.first(where: { $0.bsdName == bsdName }) {
            logger.info("NTFS disk disappeared bsd=\(bsdName) name=\(volume.volumeName) path=\(volume.mountPoint), cleaning up")
            _ = helperClient.send(NTFSHelperRequest(action: .unmount, mountPoint: volume.mountPoint))
        } else {
            logger.info("NTFS disk disappeared bsd=\(bsdName), cleaning up")
        }
        try? mountedVolumesStore.remove(bsdName: bsdName)
        debouncer.clear(bsdName: bsdName)
    }

    private func mountFailureAlertID(for bsdName: String) -> UUID {
        if let existing = mountFailureAlertIDs[bsdName] {
            return existing
        }
        let newID = UUID()
        mountFailureAlertIDs[bsdName] = newID
        return newID
    }
}
