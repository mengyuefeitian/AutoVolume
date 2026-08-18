import Foundation
import Observation
import AutoVolumeShared

public enum AppLanguage: String, CaseIterable, Identifiable {
    case english
    case chinese

    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: "English"
        case .chinese: "中文"
        }
    }
}

struct AppStrings {
    let productName: String
    let emptyTitle: String
    let emptyDescription: String
    let add: String
    let edit: String
    let remove: String
    let mount: String
    let unmount: String
    let test: String
    let saveAndMount: String
    let save: String
    let cancel: String
    let name: String
    let server: String
    let remotePath: String
    let remotePathHelp: String
    let username: String
    let password: String
    let protocolLabel: String
    let mountPoint: String
    let checkInterval: String
    let everyMinutes: (Int) -> String
    let testSucceeded: String
    let mountSucceeded: String
    let saved: String
    let confirmRemove: String
    let language: String
    let showPassword: String
    let hidePassword: String
    let testReachabilitySucceeded: String
    let smbDialect: String
    let smbMultichannel: String
    let smbAsyncReads: String
    let working: String
    let testing: String
    let mounting: String
    let unmounting: String
    let unmountSucceeded: String
    let alerts: String
    let clearAlerts: String
    let noAlerts: String

    static func values(for language: AppLanguage) -> AppStrings {
        switch language {
        case .english:
            AppStrings(
                productName: "AutoVolume",
                emptyTitle: "No Volumes",
                emptyDescription: "Add a network volume to keep it connected.",
                add: "Add",
                edit: "Edit",
                remove: "Remove",
                mount: "Mount",
                unmount: "Unmount",
                test: "Test Reachability",
                saveAndMount: "Save & Mount",
                save: "Save",
                cancel: "Cancel",
                name: "Name",
                server: "Server",
                remotePath: "Remote Path",
                remotePathHelp: "Use / for WebDAV root. For SMB, use share or share/folder, for example video or media/2026. Use /, not \\.",
                username: "Username",
                password: "Password",
                protocolLabel: "Protocol",
                mountPoint: "Mount Point",
                checkInterval: "Check Interval",
                everyMinutes: { "Every \($0) minutes" },
                testSucceeded: "Connection, credentials, and remote path verified.",
                mountSucceeded: "Mount command succeeded.",
                saved: "Saved.",
                confirmRemove: "Remove this volume?",
                language: "Language",
                showPassword: "Show password",
                hidePassword: "Hide password",
                testReachabilitySucceeded: "Connection, credentials, and remote path verified.",
                smbDialect: "SMB Range",
                smbMultichannel: "SMB3 Multichannel",
                smbAsyncReads: "Async directory reads",
                working: "Working...",
                testing: "Testing...",
                mounting: "Mounting...",
                unmounting: "Unmounting...",
                unmountSucceeded: "Unmounted.",
                alerts: "Alerts",
                clearAlerts: "Clear",
                noAlerts: "No alerts"
            )
        case .chinese:
            AppStrings(
                productName: "智卷",
                emptyTitle: "暂无卷",
                emptyDescription: "添加网络卷后，智卷会保持它在线。",
                add: "添加",
                edit: "编辑",
                remove: "移除",
                mount: "挂载",
                unmount: "卸载",
                test: "测试连通性",
                saveAndMount: "保存并挂载",
                save: "保存",
                cancel: "取消",
                name: "名称",
                server: "服务器",
                remotePath: "远程路径",
                remotePathHelp: "WebDAV 根目录填 /。SMB 填共享名或共享名/文件夹，例如 video 或 media/2026。请使用 /，不要使用 \\。",
                username: "用户名",
                password: "密码",
                protocolLabel: "协议",
                mountPoint: "挂载点",
                checkInterval: "检查间隔",
                everyMinutes: { "每 \($0) 分钟" },
                testSucceeded: "服务器、账号密码和远程路径验证通过。",
                mountSucceeded: "挂载命令执行成功。",
                saved: "已保存。",
                confirmRemove: "移除此网络卷？",
                language: "语言",
                showPassword: "显示密码",
                hidePassword: "隐藏密码",
                testReachabilitySucceeded: "服务器、账号密码和远程路径验证通过。",
                smbDialect: "SMB 范围",
                smbMultichannel: "SMB3 多通道",
                smbAsyncReads: "异步目录读取",
                working: "处理中...",
                testing: "测试中...",
                mounting: "挂载中...",
                unmounting: "卸载中...",
                unmountSucceeded: "已卸载。",
                alerts: "告警",
                clearAlerts: "清空",
                noAlerts: "暂无告警"
            )
        }
    }
}

@Observable
public final class AppViewModel {
    public private(set) var volumes: [VolumeConfig] = []
    public private(set) var alerts: [VolumeAlert] = []
    public private(set) var volumeStatuses: [VolumeConfig.ID: VolumeStatus] = [:]
    public var selectedVolumeID: VolumeConfig.ID?
    public var editorVolume: VolumeConfig?
    public var editorSessionID = UUID()
    public private(set) var settings: AppSettings
    public var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.languageDefaultsKey)
        }
    }

    private let configStore: ConfigStore
    private let credentialStore: CredentialStore
    private let commandRunner: CommandRunner
    private let mountPlanner: MountPlanner
    private let connectivityTester: ConnectivityTester
    private let smbPreferencesWriter: SMBPreferencesWriter
    private let alertStore: AlertStore
    private let mountStateProvider: MountStateProvider
    private let mountExposure: MountExposure
    private let settingsStore: AppSettingsStore

    private static let languageDefaultsKey = "AutoVolume.language"

    public init(
        configStore: ConfigStore = JSONConfigStore(),
        credentialStore: CredentialStore = EncryptedFileCredentialStore(),
        commandRunner: CommandRunner = ProcessCommandRunner(),
        mountPlanner: MountPlanner = MountPlanner(),
        connectivityTester: ConnectivityTester = ConnectivityTester(),
        smbPreferencesWriter: SMBPreferencesWriter = SMBPreferencesWriter(),
        alertStore: AlertStore = AlertStore(),
        mountStateProvider: MountStateProvider = FileSystemMountStateProvider(healthCheckTimeout: 3, validatesResponsiveness: true),
        mountExposure: MountExposure = MountExposure(),
        settingsStore: AppSettingsStore = JSONAppSettingsStore()
    ) {
        self.configStore = configStore
        self.credentialStore = credentialStore
        self.commandRunner = commandRunner
        self.mountPlanner = mountPlanner
        self.connectivityTester = connectivityTester
        self.smbPreferencesWriter = smbPreferencesWriter
        self.alertStore = alertStore
        self.mountStateProvider = mountStateProvider
        self.mountExposure = mountExposure
        self.settingsStore = settingsStore
        self.volumes = (try? configStore.load()) ?? []
        self.alerts = (try? alertStore.load()) ?? []
        self.settings = (try? settingsStore.load()) ?? AppSettings()
        if let rawLanguage = UserDefaults.standard.string(forKey: Self.languageDefaultsKey),
           let savedLanguage = AppLanguage(rawValue: rawLanguage) {
            self.language = savedLanguage
        } else if Locale.autoupdatingCurrent.language.languageCode?.identifier == "zh" {
            self.language = .chinese
        } else {
            self.language = .english
        }
        migrateLegacyMountPoints()
        refreshVolumeStatuses()
    }

    var strings: AppStrings { AppStrings.values(for: language) }
    var productName: String { strings.productName }

    public func beginAddingVolume() {
        editorVolume = nil
        editorSessionID = UUID()
    }

    public func beginEditing(_ config: VolumeConfig) {
        editorVolume = config
        editorSessionID = UUID()
    }

    public func password(for config: VolumeConfig?) -> String {
        guard let config else { return "" }
        return (try? credentialStore.password(for: config.id)) ?? ""
    }

    public func add(_ config: VolumeConfig, password: String?) throws {
        volumes.append(config)
        try persist()
        if let password, !password.isEmpty {
            try credentialStore.savePassword(password, for: config.id)
        }
        if config.protocolType == .smb {
            try smbPreferencesWriter.apply(options: config.smbOptions)
        }
        refreshVolumeStatuses()
    }

    public func save(_ config: VolumeConfig, password: String?) throws {
        if let index = volumes.firstIndex(where: { $0.id == config.id }) {
            volumes[index] = config
        } else {
            volumes.append(config)
        }
        try persist()
        if let password, !password.isEmpty {
            try credentialStore.savePassword(password, for: config.id)
        }
        refreshVolumeStatuses()
    }

    public func delete(_ config: VolumeConfig) throws {
        volumes.removeAll { $0.id == config.id }
        try persist()
        try credentialStore.deletePassword(for: config.id)
        try? alertStore.resolve(volumeID: config.id)
        refreshAlerts()
    }

    public func updateSettings(_ newSettings: AppSettings) {
        do {
            try settingsStore.save(newSettings)
            settings = newSettings
            AutoVolumeLogger.shared.info("Settings updated: logLevel=\(newSettings.logLevel), openFinderAfterMount=\(newSettings.openFinderAfterMount)")
        } catch {
            AutoVolumeLogger.shared.error("Settings save failed: \(error.localizedDescription)")
        }
    }

    public func refreshAlerts() {
        alerts = (try? alertStore.load()) ?? []
        refreshVolumeStatuses()
    }

    public func refreshAlertsOnly() {
        alerts = (try? alertStore.load()) ?? []
    }

    public func clearAlerts() {
        try? alertStore.clear()
        refreshAlerts()
    }

    public func refreshVolumeStatuses() {
        var statuses: [VolumeConfig.ID: VolumeStatus] = [:]
        for volume in volumes {
            if mountStateProvider.isMounted(config: volume) {
                statuses[volume.id] = .mounted
            } else if let alert = alerts.first(where: { $0.volumeID == volume.id }) {
                statuses[volume.id] = .failed(message: alert.message)
            } else {
                statuses[volume.id] = .unmounted
            }
        }
        volumeStatuses = statuses
    }

    public func testConnection(_ config: VolumeConfig, password: String?) throws -> String {
        AutoVolumeLogger.shared.info("Testing connection for \(config.name) \(config.protocolType.rawValue)")
        if config.protocolType == .webdav {
            try verifyConnectivity(for: config, password: password, action: "Connection test")
            AutoVolumeLogger.shared.info("Connection test passed for \(config.name)")
            return strings.testSucceeded
        }

        let result = try runTemporaryMountTest(for: config, password: password)
        guard result.exitCode == 0 else {
            AutoVolumeLogger.shared.warning("Connection test failed for \(config.name): \(commandFailureMessage(result, action: "Connection test"))")
            throw AppViewModelError.commandFailed(commandFailureMessage(result, action: "Connection test"))
        }
        AutoVolumeLogger.shared.info("Connection test passed for \(config.name)")
        return strings.testSucceeded
    }

    public func testConnectionAsync(_ config: VolumeConfig, password: String?) async throws -> String {
        try await Task.detached {
            try self.testConnection(config, password: password)
        }.value
    }

    public func mount(_ config: VolumeConfig, password: String? = nil) throws -> String {
        AutoVolumeLogger.shared.info("Mount requested for \(config.name) \(config.protocolType.rawValue)")
        let storedPassword = try password ?? credentialStore.password(for: config.id)
        if config.protocolType == .smb {
            try smbPreferencesWriter.apply(options: config.smbOptions)
        }
        try runMountCommand(for: config, password: storedPassword)
        if mountPlanner.shouldOpenFinderAfterMount(for: config) {
            let openResult = try openMountedVolume(config)
            if openResult.exitCode != 0 {
                AutoVolumeLogger.shared.warning("Finder open failed for \(config.name): \(commandFailureMessage(openResult, action: "Finder"))")
                throw AppViewModelError.commandFailed(finderOpenFailureMessage(openResult))
            }
        }
        AutoVolumeLogger.shared.info("Mount succeeded for \(config.name)")
        return strings.mountSucceeded
    }

    public func mountAsync(_ config: VolumeConfig, password: String? = nil) async throws -> String {
        try await Task.detached {
            try self.mount(config, password: password)
        }.value
    }

    public func saveAsync(_ config: VolumeConfig, password: String?) async throws {
        try save(config, password: password)
    }

    public func unmount(_ config: VolumeConfig) throws {
        AutoVolumeLogger.shared.info("Unmount requested for \(config.name)")
        let mountPoint = mountPlanner.unmountTarget(for: config)
        let result = try commandRunner.run(mountPlanner.unmountPlan(mountPoint: mountPoint))
        guard result.exitCode == 0 else {
            let forceResult = try commandRunner.run(mountPlanner.forceUnmountPlan(mountPoint: mountPoint))
            if forceResult.exitCode != 0 {
                AutoVolumeLogger.shared.warning("Unmount failed for \(config.name): \(commandFailureMessage(forceResult, action: "Unmount"))")
                throw AppViewModelError.commandFailed(commandFailureMessage(forceResult, action: "Unmount"))
            }
            refreshVolumeStatuses()
            AutoVolumeLogger.shared.info("Force unmount succeeded for \(config.name)")
            return
        }
        refreshVolumeStatuses()
        AutoVolumeLogger.shared.info("Unmount succeeded for \(config.name)")
    }

    public func unmountAsync(_ config: VolumeConfig) async throws {
        try await Task.detached {
            try self.unmount(config)
        }.value
    }

    private func persist() throws {
        try configStore.save(volumes)
    }

    private func migrateLegacyMountPoints() {
        let root = Self.defaultMountRoot
        var didChange = false
        for index in volumes.indices {
            let mountPoint = volumes[index].mountPoint.trimmingCharacters(in: .whitespacesAndNewlines)
            if mountPoint == root || mountPoint == root + "/" {
                volumes[index].mountPoint = Self.defaultMountPoint(for: volumes[index].name)
                didChange = true
            }
        }
        if didChange {
            try? persist()
        }
    }

    private static var defaultMountRoot: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Volumes", isDirectory: true)
            .path
    }

    public static func defaultMountPoint(for name: String) -> String {
        let fallback = "AutoVolume"
        let sanitizedName = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        return URL(fileURLWithPath: defaultMountRoot)
            .appendingPathComponent(sanitizedName.isEmpty ? fallback : sanitizedName, isDirectory: true)
            .path
    }

    private func runMountCommand(for config: VolumeConfig, password: String?) throws {
        if config.protocolType == .webdav {
            try verifyConnectivity(for: config, password: password, action: "Mount")
        }
        try mountExposure.prepare(config: config, planner: mountPlanner)
        let result = try runMountWithRecovery(for: config, password: password)
        guard result.exitCode == 0 else {
            throw AppViewModelError.commandFailed(mountFailureMessage(for: config, result: result))
        }
        try mountExposure.expose(config: config, planner: mountPlanner)
        guard waitForMountedVolumeResponse(config) else {
            throw AppViewModelError.commandFailed("Mount command succeeded, but the mounted volume did not respond.")
        }
        try? alertStore.resolve(volumeID: config.id)
        refreshAlerts()
    }

    private func verifyConnectivity(for config: VolumeConfig, password: String?, action: String) throws {
        let plan = try connectivityTester.testPlan(for: config, password: password)
        let result = try commandRunner.run(plan).redacting(secrets: [password])
        let connectivity = connectivityTester.checkResult(for: config, result: result)
        guard connectivity.isReachable else {
            throw AppViewModelError.commandFailed(connectivity.message ?? commandFailureMessage(result, action: action))
        }
    }

    private func openMountedVolume(_ config: VolumeConfig) throws -> CommandResult {
        let browsePath = mountPlanner.resolvedBrowsePath(for: config)
        Thread.sleep(forTimeInterval: 0.6)
        guard PathHealthProbe(timeout: 3).isResponsive(path: browsePath) else {
            return CommandResult(exitCode: 1, stdout: "", stderr: "Mounted folder is not responding at \(browsePath).")
        }
        cleanupFinderWindows(for: config, resolvedBrowsePath: browsePath)
        return try commandRunner.run(mountPlanner.finderRevealPlan(for: config, resolvedBrowsePath: browsePath))
    }

    private func cleanupFinderWindows(for config: VolumeConfig, resolvedBrowsePath: String) {
        let paths = mountPlanner.finderCleanupPaths(for: config, resolvedBrowsePath: resolvedBrowsePath)
        guard !paths.isEmpty else { return }
        let script = """
        tell application "Finder"
            repeat with windowPath in {\(paths.map { "\"\(Self.appleScriptEscaped($0))\"" }.joined(separator: ", "))}
                repeat with finderWindow in windows
                    try
                        if POSIX path of (target of finderWindow as alias) is (windowPath as text) then
                            close finderWindow
                        end if
                    end try
                end repeat
            end repeat
        end tell
        """
        _ = try? commandRunner.run(CommandPlan(executable: "/usr/bin/osascript", arguments: ["-"], standardInput: script))
    }

    private func runTemporaryMountTest(for config: VolumeConfig, password: String?) throws -> CommandResult {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoVolumeConnectionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let testMountPoint = testRoot.appendingPathComponent(config.name.isEmpty ? "Volume" : config.name, isDirectory: true).path
        let testConfig = VolumeConfig(
            id: config.id,
            name: config.name,
            protocolType: config.protocolType,
            server: config.server,
            remotePath: config.remotePath,
            username: config.username,
            mountPoint: testMountPoint,
            checkIntervalSeconds: config.checkIntervalSeconds,
            isEnabled: config.isEnabled,
            smbOptions: config.smbOptions
        )
        defer {
            let mountPoint = mountPlanner.effectiveMountPoint(for: testConfig)
            _ = try? commandRunner.run(mountPlanner.unmountPlan(mountPoint: mountPoint))
            _ = try? commandRunner.run(mountPlanner.forceUnmountPlan(mountPoint: mountPoint))
            try? FileManager.default.removeItem(at: testRoot)
        }

        try mountExposure.prepare(config: testConfig, planner: mountPlanner)
        let result = try runMountWithRecovery(for: testConfig, password: password)
        guard result.exitCode == 0 else { return result }
        try mountExposure.expose(config: testConfig, planner: mountPlanner)
        let probePath = mountPlanner.exposedPathTarget(for: testConfig) ?? mountPlanner.effectiveMountPoint(for: testConfig)
        guard PathHealthProbe(timeout: 5).isResponsive(path: probePath) else {
            return CommandResult(exitCode: 1, stdout: "", stderr: "Mounted volume did not respond at the configured remote path.")
        }
        return result
    }

    private func runMountWithRecovery(for config: VolumeConfig, password: String?) throws -> CommandResult {
        let plan = try mountPlanner.mountPlan(for: config, password: password, suppressesUserInterface: true)
        let result = try commandRunner.run(plan).redacting(secrets: [password])
        if result.exitCode == 0 {
            guard !mountedVolumeIsStale(config) else {
                unmountStaleTarget(for: config)
                let retryResult = try commandRunner.run(plan).redacting(secrets: [password])
                guard retryResult.exitCode == 0 else { return retryResult }
                return waitForMountedVolumeResponse(config)
                    ? retryResult
                    : CommandResult(exitCode: 1, stdout: retryResult.stdout, stderr: "Mount command succeeded, but the mounted volume did not respond after clearing a stale mount.")
            }
            return waitForMountedVolumeResponse(config)
                ? result
                : CommandResult(exitCode: 1, stdout: result.stdout, stderr: "Mount command succeeded, but the mounted volume did not respond.")
        }

        guard isOccupiedMountPointError(result) else {
            return result
        }

        unmountStaleTarget(for: config)
        let retryResult = try commandRunner.run(plan).redacting(secrets: [password])
        guard retryResult.exitCode == 0 else { return retryResult }
        return waitForMountedVolumeResponse(config)
            ? retryResult
            : CommandResult(exitCode: 1, stdout: retryResult.stdout, stderr: "Mount command succeeded, but the mounted volume did not respond after clearing an occupied mount point.")
    }

    private func waitForMountedVolumeResponse(_ config: VolumeConfig) -> Bool {
        for attempt in 0..<3 {
            if mountedVolumeIsResponsive(config) {
                return true
            }
            if attempt < 2 {
                Thread.sleep(forTimeInterval: 0.8)
            }
        }
        return false
    }

    private func mountedVolumeIsStale(_ config: VolumeConfig) -> Bool {
        SystemMountTable().contains(config: config) && !mountedVolumeIsResponsive(config)
    }

    private func mountedVolumeIsResponsive(_ config: VolumeConfig) -> Bool {
        PathHealthProbe(timeout: 3).isResponsive(path: mountPlanner.healthCheckPath(for: config))
    }

    private func unmountStaleTarget(for config: VolumeConfig) {
        let mountPoint = mountPlanner.unmountTarget(for: config)
        _ = try? commandRunner.run(mountPlanner.unmountPlan(mountPoint: mountPoint))
        _ = try? commandRunner.run(mountPlanner.forceUnmountPlan(mountPoint: mountPoint))
    }

    private func isOccupiedMountPointError(_ result: CommandResult) -> Bool {
        let message = "\(result.stdout)\n\(result.stderr)".lowercased()
        return message.contains("file exists") || message.contains("resource busy") || message.contains("already mounted")
    }

    private func commandFailureMessage(_ result: CommandResult, action: String) -> String {
        let detail = result.stderr.isEmpty ? result.stdout : result.stderr
        if detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(action) failed with exit code \(result.exitCode)."
        }
        return detail
    }

    private func mountFailureMessage(for config: VolumeConfig, result: CommandResult) -> String {
        let detail = result.stderr.isEmpty ? result.stdout : result.stderr
        if config.protocolType == .webdav, detail.contains("-5014") {
            switch language {
            case .chinese:
                return "macOS WebDAV/Finder 挂载服务返回 -5014。AutoVolume 已验证到这是系统挂载层异常，不是账号密码错误；请先退出 AutoVolume 并重启 macOS，重启后通常会立即恢复。"
            case .english:
                return "macOS WebDAV/Finder mount service returned -5014. This is a macOS mount-layer failure, not a credential error; quit AutoVolume and restart macOS, which usually clears it."
            }
        }
        if config.protocolType == .webdav, result.exitCode == 22 {
            return "WebDAV connectivity passed, but macOS Finder mount failed with exit code 22."
        }
        return commandFailureMessage(result, action: "Mount")
    }

    private func finderOpenFailureMessage(_ result: CommandResult) -> String {
        let detail = commandFailureMessage(result, action: "Finder")
        switch language {
        case .chinese:
            return "挂载后 Finder 无法打开目标目录：\(detail)"
        case .english:
            return "Mounted, but Finder could not open the target folder: \(detail)"
        }
    }

    private static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

}

enum AppViewModelError: Error, LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            message.isEmpty ? "Command failed." : message
        }
    }
}
