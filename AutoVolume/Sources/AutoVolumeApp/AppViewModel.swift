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
                test: "Test",
                saveAndMount: "Save & Mount",
                save: "Save",
                cancel: "Cancel",
                name: "Name",
                server: "Server",
                remotePath: "Remote Path",
                username: "Username",
                password: "Password",
                protocolLabel: "Protocol",
                mountPoint: "Mount Point",
                checkInterval: "Check Interval",
                everyMinutes: { "Every \($0) minutes" },
                testSucceeded: "Connection command succeeded.",
                mountSucceeded: "Mount command succeeded.",
                saved: "Saved.",
                confirmRemove: "Remove this volume?",
                language: "Language",
                showPassword: "Show password",
                hidePassword: "Hide password",
                testReachabilitySucceeded: "Server is reachable. Credentials are verified during mount.",
                smbDialect: "SMB Mode",
                smbMultichannel: "SMB3 Multichannel",
                smbAsyncReads: "Async directory reads"
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
                test: "测试",
                saveAndMount: "保存并挂载",
                save: "保存",
                cancel: "取消",
                name: "名称",
                server: "服务器",
                remotePath: "远程路径",
                username: "用户名",
                password: "密码",
                protocolLabel: "协议",
                mountPoint: "挂载点",
                checkInterval: "检查间隔",
                everyMinutes: { "每 \($0) 分钟" },
                testSucceeded: "连接命令执行成功。",
                mountSucceeded: "挂载命令执行成功。",
                saved: "已保存。",
                confirmRemove: "移除此网络卷？",
                language: "语言",
                showPassword: "显示密码",
                hidePassword: "隐藏密码",
                testReachabilitySucceeded: "服务器可达。账号密码会在挂载时验证。",
                smbDialect: "SMB 模式",
                smbMultichannel: "SMB3 多通道",
                smbAsyncReads: "异步目录读取"
            )
        }
    }
}

@Observable
public final class AppViewModel {
    public private(set) var volumes: [VolumeConfig] = []
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

    private static let languageDefaultsKey = "AutoVolume.language"

    public init(
        configStore: ConfigStore = JSONConfigStore(),
        credentialStore: CredentialStore = KeychainCredentialStore(),
        commandRunner: CommandRunner = ProcessCommandRunner(),
        mountPlanner: MountPlanner = MountPlanner(),
        connectivityTester: ConnectivityTester = ConnectivityTester(),
        smbPreferencesWriter: SMBPreferencesWriter = SMBPreferencesWriter()
    ) {
        self.configStore = configStore
        self.credentialStore = credentialStore
        self.commandRunner = commandRunner
        self.mountPlanner = mountPlanner
        self.connectivityTester = connectivityTester
        self.smbPreferencesWriter = smbPreferencesWriter
        self.volumes = (try? configStore.load()) ?? []
        if let rawLanguage = UserDefaults.standard.string(forKey: Self.languageDefaultsKey),
           let savedLanguage = AppLanguage(rawValue: rawLanguage) {
            self.language = savedLanguage
        } else if Locale.autoupdatingCurrent.language.languageCode?.identifier == "zh" {
            self.language = .chinese
        } else {
            self.language = .english
        }
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
    }

    public func delete(_ config: VolumeConfig) throws {
        volumes.removeAll { $0.id == config.id }
        try persist()
        try credentialStore.deletePassword(for: config.id)
    }

    public func testConnection(_ config: VolumeConfig, password: String?) throws -> String {
        let result = try commandRunner.run(try connectivityTester.testPlan(for: config, password: password))
        guard result.exitCode == 0 else {
            throw AppViewModelError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return config.protocolType == .webdav ? strings.testSucceeded : strings.testReachabilitySucceeded
    }

    public func mount(_ config: VolumeConfig, password: String? = nil) throws -> String {
        let storedPassword = try password ?? credentialStore.password(for: config.id)
        if config.protocolType == .smb {
            try smbPreferencesWriter.apply(options: config.smbOptions)
        }
        try runMountCommand(for: config, password: storedPassword)
        return strings.mountSucceeded
    }

    public func unmount(_ config: VolumeConfig) throws {
        let result = try commandRunner.run(mountPlanner.unmountPlan(mountPoint: config.mountPoint))
        guard result.exitCode == 0 else {
            throw AppViewModelError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    private func persist() throws {
        try configStore.save(volumes)
    }

    private func runMountCommand(for config: VolumeConfig, password: String?) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: config.mountPoint),
            withIntermediateDirectories: true
        )
        let result = try commandRunner.run(try mountPlanner.mountPlan(for: config, password: password))
        guard result.exitCode == 0 else {
            throw AppViewModelError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
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
