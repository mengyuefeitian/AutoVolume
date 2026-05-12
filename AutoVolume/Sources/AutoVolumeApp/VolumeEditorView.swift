import SwiftUI
import AutoVolumeShared

struct VolumeEditorView: View {
    let viewModel: AppViewModel
    let volume: VolumeConfig?
    let onCancel: () -> Void
    let onSaved: (String) -> Void

    @State private var name = ""
    @State private var protocolType = VolumeProtocol.smb
    @State private var server = ""
    @State private var remotePath = ""
    @State private var username = ""
    @State private var password = ""
    @State private var mountPoint = Self.defaultMountRoot
    @State private var intervalMinutes = 5.0
    @State private var message: String?
    @State private var isPasswordVisible = false
    @Environment(\.dismissWindow) private var dismissWindow

    init(
        viewModel: AppViewModel,
        volume: VolumeConfig? = nil,
        onCancel: @escaping () -> Void = {},
        onSaved: @escaping (String) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.volume = volume
        self.onCancel = onCancel
        self.onSaved = onSaved
        _name = State(initialValue: volume?.name ?? "")
        _protocolType = State(initialValue: volume?.protocolType ?? .smb)
        _server = State(initialValue: volume?.server ?? "")
        _remotePath = State(initialValue: volume?.remotePath ?? "")
        _username = State(initialValue: volume?.username ?? "")
        _mountPoint = State(initialValue: volume?.mountPoint ?? Self.defaultMountRoot)
        _intervalMinutes = State(initialValue: max(1, (volume?.checkIntervalSeconds ?? 300) / 60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(viewModel.strings.name)
                    TextField(viewModel.strings.name, text: $name)
                }
                GridRow {
                    Text(viewModel.strings.protocolLabel)
                    Picker(viewModel.strings.protocolLabel, selection: $protocolType) {
                        ForEach(VolumeProtocol.allCases) { item in
                            Text(item.rawValue.uppercased()).tag(item)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text(viewModel.strings.server)
                    TextField(viewModel.strings.server, text: $server)
                }
                GridRow {
                    Text(viewModel.strings.remotePath)
                    TextField(viewModel.strings.remotePath, text: $remotePath)
                }
                GridRow {
                    Text(viewModel.strings.username)
                    TextField(viewModel.strings.username, text: $username)
                }
                GridRow {
                    Text(viewModel.strings.password)
                    HStack {
                        if isPasswordVisible {
                            TextField(viewModel.strings.password, text: $password)
                        } else {
                            SecureField(viewModel.strings.password, text: $password)
                        }
                        Button {
                            isPasswordVisible.toggle()
                        } label: {
                            Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(isPasswordVisible ? viewModel.strings.hidePassword : viewModel.strings.showPassword)
                    }
                }
                GridRow {
                    Text(viewModel.strings.mountPoint)
                    TextField(viewModel.strings.mountPoint, text: $mountPoint)
                }
            }
            Slider(value: $intervalMinutes, in: 1...60, step: 1) {
                Text(viewModel.strings.checkInterval)
            }
            Text(viewModel.strings.everyMinutes(Int(intervalMinutes)))
                .foregroundStyle(.secondary)

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(viewModel.strings.cancel) {
                    onCancel()
                    dismissWindow(id: "volume-editor")
                }
                Spacer()
                Button(viewModel.strings.test) {
                    do {
                        message = try viewModel.testConnection(makeConfig(), password: password.isEmpty ? nil : password)
                    } catch {
                        message = error.localizedDescription
                    }
                }
                Button(viewModel.strings.saveAndMount) {
                    do {
                        let config = makeConfig()
                        try viewModel.save(config, password: password.isEmpty ? nil : password)
                        let result = try viewModel.mount(config, password: password.isEmpty ? nil : password)
                        onSaved(result)
                        dismissWindow(id: "volume-editor")
                    } catch {
                        message = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    private func makeConfig() -> VolumeConfig {
        VolumeConfig(
            id: volume?.id ?? UUID(),
            name: name,
            protocolType: protocolType,
            server: server,
            remotePath: remotePath,
            username: username.isEmpty ? nil : username,
            mountPoint: mountPoint,
            checkIntervalSeconds: intervalMinutes * 60,
            isEnabled: true
        )
    }

    private static var defaultMountRoot: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Volumes", isDirectory: true)
            .path + "/"
    }
}
