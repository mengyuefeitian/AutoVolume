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

    private static let languageDefaultsKey = "AutoVolume.language"

    public init(
        configStore: ConfigStore = JSONConfigStore(),
        credentialStore: CredentialStore = EncryptedFileCredentialStore(),
        commandRunner: CommandRunner = ProcessCommandRunner(),
        mountPlanner: MountPlanner = MountPlanner(),
        connectivityTester: ConnectivityTester = ConnectivityTester(),
        smbPreferencesWriter: SMBPreferencesWriter = SMBPreferencesWriter(),
        alertStore: AlertStore = AlertStore(),
        mountStateProvider: MountStateProvider = FileSystemMountStateProvider(validatesResponsiveness: false),
        mountExposure: MountExposure = MountExposure()
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
        self.volumes = (try? configStore.load()) ?? []
        self.alerts = (try? alertStore.load()) ?? []
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

    public func refreshAlerts() {
        alerts = (try? alertStore.load()) ?? []
        refreshVolumeStatuses()
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
        let result = try runTemporaryMountTest(for: config, password: password)
        guard result.exitCode == 0 else {
            throw AppViewModelError.commandFailed(commandFailureMessage(result, action: "Connection test"))
        }
        return strings.testSucceeded
    }

    public func testConnectionAsync(_ config: VolumeConfig, password: String?) async throws -> String {
        try await Task.detached {
            try self.testConnection(config, password: password)
        }.value
    }

    public func mount(_ config: VolumeConfig, password: String? = nil) throws -> String {
        let storedPassword = try password ?? credentialStore.password(for: config.id)
        if config.protocolType == .smb {
            try smbPreferencesWriter.apply(options: config.smbOptions)
        }
        try runMountCommand(for: config, password: storedPassword)
        if mountPlanner.shouldOpenFinderAfterMount(for: config) {
            let openResult = try openMountedVolume(config)
            if openResult.exitCode != 0 {
                return "\(strings.mountSucceeded) Finder open failed: \(commandFailureMessage(openResult, action: "Finder"))"
            }
        }
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
        let mountPoint = mountPlanner.unmountTarget(for: config)
        let result = try commandRunner.run(mountPlanner.unmountPlan(mountPoint: mountPoint))
        guard result.exitCode == 0 else {
            let forceResult = try commandRunner.run(mountPlanner.forceUnmountPlan(mountPoint: mountPoint))
            if forceResult.exitCode != 0 {
                throw AppViewModelError.commandFailed(commandFailureMessage(forceResult, action: "Unmount"))
            }
            refreshVolumeStatuses()
            return
        }
        refreshVolumeStatuses()
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
        try mountExposure.prepare(config: config, planner: mountPlanner)
        let result = try runMountWithRecovery(for: config, password: password)
        guard result.exitCode == 0 else {
            throw AppViewModelError.commandFailed(commandFailureMessage(result, action: "Mount"))
        }
        try mountExposure.expose(config: config, planner: mountPlanner)
        try? alertStore.resolve(volumeID: config.id)
        refreshAlerts()
    }

    private func openMountedVolume(_ config: VolumeConfig) throws -> CommandResult {
        let browsePath = mountPlanner.browsePath(for: config)
        Thread.sleep(forTimeInterval: 0.6)
        let script = """
        tell application "Finder"
            activate
            make new Finder window to (POSIX file "\(Self.appleScriptEscaped(browsePath))" as alias)
        end tell
        """
        return try commandRunner.run(CommandPlan(executable: "/usr/bin/osascript", arguments: ["-"], standardInput: script))
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
        guard result.exitCode != 0, isOccupiedMountPointError(result) else {
            return result
        }

        let mountPoint = mountPlanner.effectiveMountPoint(for: config)
        _ = try? commandRunner.run(mountPlanner.unmountPlan(mountPoint: mountPoint))
        _ = try? commandRunner.run(mountPlanner.forceUnmountPlan(mountPoint: mountPoint))
        return try commandRunner.run(plan).redacting(secrets: [password])
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
