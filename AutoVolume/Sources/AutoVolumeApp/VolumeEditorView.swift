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
    @State private var nfsMode = NFSMountMode.hard
    @State private var nfsVersion = NFSVersion.v3
    @State private var nfsExports: [String] = []
    @State private var smbAsyncDirectoryQueryCount = 10.0
    @State private var message: String?
    @State private var isPasswordVisible = false
    @State private var isWorking = false

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
        _nfsMode = State(initialValue: volume?.nfsOptions.mode ?? .hard)
        _nfsVersion = State(initialValue: volume?.nfsOptions.version ?? .v3)
    }

    var body: some View {
        let _ = viewModel.languageRevision
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow {
                            Text(L10n.t(.editorName))
                            editorTextField(L10n.t(.editorName), text: $name, focusesOnAppear: true)
                        }
                        GridRow {
                            Text(L10n.t(.editorProtocolLabel))
                            Picker(L10n.t(.editorProtocolLabel), selection: $protocolType) {
                                ForEach(VolumeProtocol.allCases) { item in
                                    Text(item.rawValue.uppercased()).tag(item)
                                }
                            }
                            .labelsHidden()
                        }
                        GridRow {
                            Text(L10n.t(.editorServer))
                            editorTextField(L10n.t(.editorServer), text: $server)
                        }
                        GridRow {
                            Text(L10n.t(.editorRemotePath))
                                .gridCellAnchor(.topLeading)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    editorTextField(L10n.t(.editorRemotePath), text: $remotePath)
                                    if protocolType == .nfs {
                                        Button(L10n.t(.editorNfsListExports)) {
                                            Task { await loadNFSExports() }
                                        }
                                        .disabled(isWorking || server.trimmingCharacters(in: .whitespaces).isEmpty)
                                        if !nfsExports.isEmpty {
                                            Menu {
                                                ForEach(nfsExports, id: \.self) { path in
                                                    Button(path) { remotePath = path }
                                                }
                                            } label: {
                                                Image(systemName: "list.bullet")
                                            }
                                            .menuStyle(.borderlessButton)
                                            .fixedSize()
                                        }
                                    }
                                }
                                Text(L10n.t(protocolType == .nfs ? .editorRemotePathHelpNFS : .editorRemotePathHelp))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        // NFSv3 has no passwords: the NAS decides by the Mac's IP address (and the share's
                        // squash/mapping rules), so there is nothing to fill in.
                        if protocolType != .nfs {
                            GridRow {
                                Text(L10n.t(.editorUsername))
                                editorTextField(L10n.t(.editorUsername), text: $username)
                            }
                            GridRow {
                                Text(L10n.t(.editorPassword))
                                HStack {
                                    if isPasswordVisible {
                                        editorTextField(L10n.t(.editorPassword), text: $password)
                                    } else {
                                        editorTextField(L10n.t(.editorPassword), text: $password, isSecure: true)
                                    }
                                    Button {
                                        isPasswordVisible.toggle()
                                    } label: {
                                        Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                                    }
                                    .buttonStyle(.borderless)
                                    .help(isPasswordVisible ? L10n.t(.editorHidePassword) : L10n.t(.editorShowPassword))
                                }
                            }
                        }
                        GridRow {
                            Text(L10n.t(.editorMountPoint))
                            editorTextField(L10n.t(.editorMountPoint), text: $mountPoint)
                        }
                        // Label in its own grid column so it can never overlap the slider track.
                        GridRow {
                            Text(L10n.t(.editorCheckInterval))
                            Slider(value: $intervalMinutes, in: 1...60, step: 1)
                                .accessibilityLabel(L10n.t(.editorCheckInterval))
                        }
                        GridRow {
                            Color.clear.frame(width: 0, height: 0)
                            Text(L10n.t(.editorEveryMinutes, String(Int(intervalMinutes))))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if protocolType == .nfs {
                        Divider()
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                            GridRow {
                                Text(L10n.t(.editorNfsMode))
                                Picker(L10n.t(.editorNfsMode), selection: $nfsMode) {
                                    Text(L10n.t(.editorNfsModeHard)).tag(NFSMountMode.hard)
                                    Text(L10n.t(.editorNfsModeSoft)).tag(NFSMountMode.soft)
                                }
                                .labelsHidden()
                            }
                            GridRow {
                                Text("")
                                Text(L10n.t(.editorNfsModeHelp))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            GridRow {
                                Text(L10n.t(.editorNfsVersion))
                                Picker(L10n.t(.editorNfsVersion), selection: $nfsVersion) {
                                    Text("NFSv3").tag(NFSVersion.v3)
                                    Text(L10n.t(.editorNfsVersion41)).tag(NFSVersion.v4_1)
                                    Text(L10n.t(.editorNfsVersionAuto)).tag(NFSVersion.auto)
                                }
                                .labelsHidden()
                            }
                        }
                    }

                    if protocolType == .smb {
                        Divider()
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                            GridRow {
                                Text(L10n.t(.editorSmbDialect))
                                Picker(L10n.t(.editorSmbDialect), selection: $smbDialect) {
                                    ForEach(SMBDialect.allCases) { dialect in
                                        Text(dialect.displayName).tag(dialect)
                                    }
                                }
                                .labelsHidden()
                            }
                            GridRow {
                                Text(L10n.t(.editorSmbMultichannel))
                                Toggle("", isOn: $isSMBMultichannelEnabled)
                                    .labelsHidden()
                            }
                            GridRow {
                                Text(L10n.t(.editorSmbAsyncReads))
                                Stepper("\(Int(smbAsyncDirectoryQueryCount))", value: $smbAsyncDirectoryQueryCount, in: 1...64, step: 1)
                            }
                        }
                    }
                }
                .padding(.trailing, 12)
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
                    Text(L10n.t(.statusWorking))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button(L10n.t(.editorCancel)) {
                    AutoVolumeLogger.shared.info("Cancel button selected")
                    onCancel()
                }
                .glassButtonStyle()
                .disabled(isWorking)
                Spacer()
                Button(L10n.t(.editorTest)) {
                    Task {
                        await runAsync(status: L10n.t(.statusTesting), closeOnSuccess: false, validatesMountPoint: false) {
                            let (config, note) = await configWithResolvedNFSPath()
                            let result = try await viewModel.testConnectionAsync(config, password: password.isEmpty ? nil : password)
                            return joined(note, result)
                        }
                    }
                }
                .glassButtonStyle()
                .disabled(isWorking)
                Button(L10n.t(.editorSave)) {
                    Task {
                        await runAsync(status: L10n.t(.statusWorking), closeOnSuccess: true) {
                            let (config, note) = await configWithResolvedNFSPath()
                            try await viewModel.saveAsync(config, password: password.isEmpty ? nil : password)
                            return joined(note, L10n.t(.statusSaved))
                        }
                    }
                }
                .glassButtonStyle()
                .disabled(isWorking)
                Button(L10n.t(.editorSaveAndMount)) {
                    Task {
                        await runAsync(status: L10n.t(.statusMounting), closeOnSuccess: true) {
                            let (config, note) = await configWithResolvedNFSPath()
                            try await viewModel.saveAsync(config, password: password.isEmpty ? nil : password)
                            do {
                                return joined(note, try await viewModel.mountAsync(config, password: password.isEmpty ? nil : password))
                            } catch {
                                return joined(note, "\(L10n.t(.statusSaved)) \(error.localizedDescription)")
                            }
                        }
                    }
                }
                .glassButtonStyle(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking)
            }
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .onChange(of: server) { nfsExports = [] }
    }

    /// For NFS, replaces a share name with the server's full export path ("video" -> "/volume1/video")
    /// in both the field and the config about to be tested/saved, so the saved volume is one the agent
    /// can actually mount. Any other protocol, or a path that needs no fixing, passes through untouched.
    @MainActor
    private func configWithResolvedNFSPath() async -> (VolumeConfig, String?) {
        var config = makeConfig()
        guard let corrected = await viewModel.correctedNFSPath(for: config) else { return (config, nil) }
        remotePath = corrected
        config.remotePath = corrected
        return (config, L10n.t(.statusNFSPathCorrected, corrected))
    }

    private func joined(_ note: String?, _ message: String) -> String {
        [note, message].compactMap { $0 }.joined(separator: " ")
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
            ),
            nfsOptions: NFSOptions(mode: nfsMode, version: nfsVersion)
        )
    }

    private func resolvedMountPoint() -> String {
        let trimmedMountPoint = (mountPoint.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        let legacyRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Volumes", isDirectory: true)
            .path
        if trimmedMountPoint.isEmpty || trimmedMountPoint == legacyRoot || trimmedMountPoint == legacyRoot + "/" || trimmedMountPoint == AppViewModel.defaultMountPoint(for: "") {
            return AppViewModel.defaultMountPoint(for: name)
        }
        return trimmedMountPoint
    }

    private func editorTextField(
        _ placeholder: String,
        text: Binding<String>,
        isSecure: Bool = false,
        focusesOnAppear: Bool = false
    ) -> some View {
        AppKitTextField(placeholder, text: text, isSecure: isSecure, focusesOnAppear: focusesOnAppear)
            .frame(height: 34)
            .padding(.vertical, 3)
    }

    @MainActor
    private func loadNFSExports() async {
        isWorking = true
        message = L10n.t(.statusWorking)
        let exports = await viewModel.listNFSExports(server: server)
        nfsExports = exports ?? []
        message = exports == nil || exports?.isEmpty == true ? L10n.t(.editorNfsExportsNone) : nil
        isWorking = false
    }

    @MainActor
    private func runAsync(status: String, closeOnSuccess: Bool, validatesMountPoint: Bool = true, operation: @escaping () async throws -> String) async {
        if validatesMountPoint, let problem = await viewModel.mountPointProblem(for: makeConfig(), previousMountPoint: volume?.mountPoint) {
            message = problem
            return
        }
        isWorking = true
        message = status
        do {
            let result = try await operation()
            message = result
            onSaved(result)
            if closeOnSuccess {
                onCancel()
            }
        } catch {
            message = error.localizedDescription
        }
        isWorking = false
    }
}

enum EditorInputActivation {
    static func begin() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate(ignoringOtherApps: true)
            guard let editor = NSApp.windows.first(where: { $0.identifier?.rawValue == "volume-editor" }) else { return }
            // Switching the activation policy can shove the window to the screen's top edge; re-center.
            WindowPlacement.centerOnActiveScreen(editor)
            editor.makeKeyAndOrderFront(nil)
        }
    }

    static func end() {
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct AppKitTextField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var isSecure = false
    var focusesOnAppear = false

    init(_ placeholder: String, text: Binding<String>, isSecure: Bool = false, focusesOnAppear: Bool = false) {
        self.placeholder = placeholder
        _text = text
        self.isSecure = isSecure
        self.focusesOnAppear = focusesOnAppear
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = isSecure ? NSSecureTextField() : NSTextField()
        field.placeholderString = placeholder
        field.stringValue = text
        field.delegate = context.coordinator
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.controlSize = .large
        field.wantsLayer = true
        field.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.75).cgColor
        field.layer?.borderWidth = 1
        field.layer?.cornerRadius = 6
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if focusesOnAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak field] in
                guard let field, let window = field.window else { return }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(field)
            }
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.75).cgColor
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text = field.stringValue
        }
    }
}
