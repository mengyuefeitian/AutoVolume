import Foundation

public struct NTFSBundledInstallerPaths {
    public var fuseTInstallerPkgPath: String
    public var helperExecutablePath: String
    public var daemonPlistPath: String
    public var ntfs3gPath: String
    public var ntfs3gDylibPath: String
    public var newsyslogConfPath: String
    public var sharedDylibPath: String

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

    public init(
        settingsStore: AppSettingsStore = JSONAppSettingsStore(),
        driverInstaller: NTFSDriverInstaller = NTFSDriverInstaller(),
        helperClient: NTFSHelperClientProtocol = NTFSHelperClient(),
        mountedVolumesStore: NTFSMountedVolumesStore = NTFSMountedVolumesStore(),
        commandRunner: CommandRunner = ProcessCommandRunner(),
        alertStore: AlertStore = AlertStore(),
        debouncer: NTFSRemountDebouncer = NTFSRemountDebouncer(),
        bundledInstallerPaths: NTFSBundledInstallerPaths = NTFSBundledInstallerPaths()
    ) {
        self.settingsStore = settingsStore
        self.driverInstaller = driverInstaller
        self.helperClient = helperClient
        self.mountedVolumesStore = mountedVolumesStore
        self.commandRunner = commandRunner
        self.alertStore = alertStore
        self.debouncer = debouncer
        self.bundledInstallerPaths = bundledInstallerPaths
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
        guard !NTFSDiskClassifier.isOwnedByOurDriver(mountedFileSystemName: mountedFileSystemName) else { return }
        guard debouncer.shouldProcess(bsdName: bsdName) else { return }
        debouncer.markProcessed(bsdName: bsdName)

        let settings = (try? settingsStore.load()) ?? AppSettings()
        guard settings.autoMountNTFSReadWrite else {
            try? alertStore.record(
                volumeID: Self.onboardingAlertID,
                volumeName: volumeName,
                message: "检测到 NTFS 硬盘「\(volumeName)」。前往设置开启「NTFS 读写支持」即可以读写方式挂载。"
            )
            return
        }

        if !driverInstaller.isFullyInstalled() {
            let plan = driverInstaller.installPlan(
                bundledInstallerPkgPath: bundledInstallerPaths.fuseTInstallerPkgPath,
                bundledHelperExecutablePath: bundledInstallerPaths.helperExecutablePath,
                bundledDaemonPlistPath: bundledInstallerPaths.daemonPlistPath,
                bundledNTFS3GPath: bundledInstallerPaths.ntfs3gPath,
                bundledNTFS3GDylibPath: bundledInstallerPaths.ntfs3gDylibPath,
                bundledSharedDylibPath: bundledInstallerPaths.sharedDylibPath,
                bundledNewsyslogConfPath: bundledInstallerPaths.newsyslogConfPath
            )
            _ = try? commandRunner.run(plan)
        }

        let response = helperClient.send(NTFSHelperRequest(action: .mount, devicePath: devicePath, mountPoint: mountPoint))
        guard response.success else { return }

        try? mountedVolumesStore.add(NTFSVolume(bsdName: bsdName, volumeName: volumeName, devicePath: devicePath, mountPoint: mountPoint, mountedAt: Date()))
        try? alertStore.resolve(volumeID: Self.onboardingAlertID)
    }

    public func handleDiskDisappeared(bsdName: String) {
        try? mountedVolumesStore.remove(bsdName: bsdName)
    }
}
