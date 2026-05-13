import SwiftUI
import AppKit
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
    @State private var mountPoint = AppViewModel.defaultMountPoint(for: "")
    @State private var intervalMinutes = 5.0
    @State private var smbDialect = SMBDialect.smb3
    @State private var isSMBMultichannelEnabled = true
    @State private var smbAsyncDirectoryQueryCount = 10.0
    @State private var message: String?
    @State private var isPasswordVisible = false
    @State private var isWorking = false
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
        _password = State(initialValue: viewModel.password(for: volume))
        _mountPoint = State(initialValue: volume?.mountPoint ?? AppViewModel.defaultMountPoint(for: volume?.name ?? ""))
        _intervalMinutes = State(initialValue: max(1, (volume?.checkIntervalSeconds ?? 300) / 60))
        _smbDialect = State(initialValue: volume?.smbOptions.dialect ?? .smb3)
        _isSMBMultichannelEnabled = State(initialValue: volume?.smbOptions.isMultichannelEnabled ?? true)
        _smbAsyncDirectoryQueryCount = State(initialValue: Double(volume?.smbOptions.asyncDirectoryQueryCount ?? 10))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
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
                            VStack(alignment: .leading, spacing: 4) {
                                TextField(viewModel.strings.remotePath, text: $remotePath)
                                Text(viewModel.strings.remotePathHelp)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
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

                    if protocolType == .smb {
                        Divider()
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                            GridRow {
                                Text(viewModel.strings.smbDialect)
                                Picker(viewModel.strings.smbDialect, selection: $smbDialect) {
                                    ForEach(SMBDialect.allCases) { dialect in
                                        Text(dialect.displayName).tag(dialect)
                                    }
                                }
                                .labelsHidden()
                            }
                            GridRow {
                                Text(viewModel.strings.smbMultichannel)
                                Toggle("", isOn: $isSMBMultichannelEnabled)
                                    .labelsHidden()
                            }
                            GridRow {
                                Text(viewModel.strings.smbAsyncReads)
                                Stepper("\(Int(smbAsyncDirectoryQueryCount))", value: $smbAsyncDirectoryQueryCount, in: 1...64, step: 1)
                            }
                        }
                    }
                }
                .padding(.trailing, 8)
            }

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.strings.working)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button(viewModel.strings.cancel) {
                    onCancel()
                    dismissWindow(id: "volume-editor")
                }
                .disabled(isWorking)
                Spacer()
                Button(viewModel.strings.test) {
                    Task {
                        await runAsync(status: viewModel.strings.testing, closeOnSuccess: false) {
                            try await viewModel.testConnectionAsync(makeConfig(), password: password.isEmpty ? nil : password)
                        }
                    }
                }
                .disabled(isWorking)
                Button(viewModel.strings.save) {
                    Task {
                        await runAsync(status: viewModel.strings.working, closeOnSuccess: true) {
                            try await viewModel.saveAsync(makeConfig(), password: password.isEmpty ? nil : password)
                            return viewModel.strings.saved
                        }
                    }
                }
                .disabled(isWorking)
                Button(viewModel.strings.saveAndMount) {
                    Task {
                        await runAsync(status: viewModel.strings.mounting, closeOnSuccess: true) {
                            let config = makeConfig()
                            try await viewModel.saveAsync(config, password: password.isEmpty ? nil : password)
                            do {
                                return try await viewModel.mountAsync(config, password: password.isEmpty ? nil : password)
                            } catch {
                                return "\(viewModel.strings.saved) \(error.localizedDescription)"
                            }
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking)
            }
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
        .padding()
        .background(FloatingWindowAccessor())
    }

    private func makeConfig() -> VolumeConfig {
        VolumeConfig(
            id: volume?.id ?? UUID(),
            name: name,
            protocolType: protocolType,
            server: server,
            remotePath: remotePath,
            username: username.isEmpty ? nil : username,
            mountPoint: resolvedMountPoint(),
            checkIntervalSeconds: intervalMinutes * 60,
            isEnabled: true,
            smbOptions: SMBOptions(
                dialect: smbDialect,
                isMultichannelEnabled: isSMBMultichannelEnabled,
                asyncDirectoryQueryCount: Int(smbAsyncDirectoryQueryCount)
            )
        )
    }

    private func resolvedMountPoint() -> String {
        let trimmedMountPoint = mountPoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Volumes", isDirectory: true)
            .path
        if trimmedMountPoint.isEmpty || trimmedMountPoint == legacyRoot || trimmedMountPoint == legacyRoot + "/" || trimmedMountPoint == AppViewModel.defaultMountPoint(for: "") {
            return AppViewModel.defaultMountPoint(for: name)
        }
        return trimmedMountPoint
    }

    @MainActor
    private func runAsync(status: String, closeOnSuccess: Bool, operation: @escaping () async throws -> String) async {
        isWorking = true
        message = status
        do {
            let result = try await operation()
            message = result
            onSaved(result)
            if closeOnSuccess {
                dismissWindow(id: "volume-editor")
            }
        } catch {
            message = error.localizedDescription
        }
        isWorking = false
    }
}

private struct FloatingWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.identifier = NSUserInterfaceItemIdentifier("volume-editor")
            window.level = .floating
            window.collectionBehavior.insert(.fullScreenAuxiliary)
            window.isReleasedWhenClosed = false
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.identifier = NSUserInterfaceItemIdentifier("volume-editor")
            window.level = .floating
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }
}
