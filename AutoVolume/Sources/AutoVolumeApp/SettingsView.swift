import SwiftUI
import AutoVolumeShared

struct SettingsView: View {
    let viewModel: AppViewModel

    @State private var logLevel: LogLevel
    @State private var openFinderAfterMount: Bool
    @State private var autoMountNTFSReadWrite: Bool

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _logLevel = State(initialValue: viewModel.settings.logLevel)
        _openFinderAfterMount = State(initialValue: viewModel.settings.openFinderAfterMount)
        _autoMountNTFSReadWrite = State(initialValue: viewModel.settings.autoMountNTFSReadWrite)
    }

    var body: some View {
        Form {
            Section(localized("日志", "Logging")) {
                Picker(localized("日志错误级别", "Log Level"), selection: $logLevel) {
                    Text(localized("全部", "All")).tag(LogLevel.info)
                    Text(localized("警告及以上", "Warning and above")).tag(LogLevel.warning)
                    Text(localized("仅错误", "Errors only")).tag(LogLevel.error)
                }
                Text(localized("调整后，低于所选级别的日志将不会写入日志文件。日志文件大小限制不变。", "After adjusting, log entries below the selected level won't be written to the log file. The log file size limit is unchanged."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(localized("挂载", "Mounting")) {
                Toggle(localized("重连成功后自动在 Finder 中打开", "Open in Finder after a successful reconnect"), isOn: $openFinderAfterMount)
                Text(localized("关闭后，自动挂载或重连成功将不会自动打开 Finder 窗口。", "When off, a successful automatic mount or reconnect won't open a Finder window."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(localized("NTFS 硬盘", "NTFS Drives")) {
                Toggle(localized("自动以读写方式挂载 NTFS 外接硬盘", "Automatically mount external NTFS drives read-write"), isOn: $autoMountNTFSReadWrite)
                Text(localized("开启后，插入的 NTFS 格式硬盘会自动切换为可读写（首次开启需要输入一次管理员密码安装内置驱动，之后不再需要）。关闭时保持 macOS 原生只读挂载。", "When on, inserted NTFS drives are automatically switched to read-write (the first time requires an admin password to install the bundled driver, never again after that). When off, macOS's native read-only mount is left untouched."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 380)
        .onChange(of: logLevel) { _, newValue in
            viewModel.updateSettings(AppSettings(logLevel: newValue, openFinderAfterMount: openFinderAfterMount, autoMountNTFSReadWrite: autoMountNTFSReadWrite))
        }
        .onChange(of: openFinderAfterMount) { _, newValue in
            viewModel.updateSettings(AppSettings(logLevel: logLevel, openFinderAfterMount: newValue, autoMountNTFSReadWrite: autoMountNTFSReadWrite))
        }
        .onChange(of: autoMountNTFSReadWrite) { _, newValue in
            viewModel.updateSettings(AppSettings(logLevel: logLevel, openFinderAfterMount: openFinderAfterMount, autoMountNTFSReadWrite: newValue))
        }
    }

    private func localized(_ chinese: String, _ english: String) -> String {
        viewModel.language == .chinese ? chinese : english
    }
}
