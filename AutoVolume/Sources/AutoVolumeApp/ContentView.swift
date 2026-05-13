import SwiftUI
import AppKit
import AutoVolumeShared

struct ContentView: View {
    @Bindable var viewModel: AppViewModel
    @State private var message: String?
    @State private var workingVolumeIDs: Set<VolumeConfig.ID> = []
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(viewModel.productName, systemImage: "externaldrive.connected.to.line.below")
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                Spacer()
                Picker(viewModel.strings.language, selection: $viewModel.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
                .frame(width: 92)
                Menu {
                    if viewModel.alerts.isEmpty {
                        Text(viewModel.strings.noAlerts)
                    } else {
                        ForEach(viewModel.alerts) { alert in
                            Text("\(alert.volumeName): \(alert.message)")
                        }
                        Divider()
                        Button(viewModel.strings.clearAlerts) {
                            viewModel.clearAlerts()
                        }
                    }
                } label: {
                    Label(viewModel.strings.alerts, systemImage: viewModel.alerts.isEmpty ? "bell" : "exclamationmark.triangle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(viewModel.alerts.isEmpty ? Color.secondary : Color.orange)
                }
                .help(viewModel.strings.alerts)
                Button {
                    viewModel.beginAddingVolume()
                    openWindow(id: "volume-editor")
                    bringEditorForward()
                } label: {
                    Label(viewModel.strings.add, systemImage: "plus")
                }
                .keyboardShortcut("n")
            }

            if viewModel.volumes.isEmpty {
                ContentUnavailableView(viewModel.strings.emptyTitle, systemImage: "externaldrive.badge.plus", description: Text(viewModel.strings.emptyDescription))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.volumes) { volume in
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive")
                        VStack(alignment: .leading) {
                            Text(volume.name).font(.headline)
                            Text("\(volume.protocolType.rawValue.uppercased()) · \(volume.server)/\(volume.remotePath)")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Int(volume.checkIntervalSeconds / 60))m")
                            .foregroundStyle(.secondary)
                        Button {
                            Task {
                                await mount(volume)
                            }
                        } label: {
                            if workingVolumeIDs.contains(volume.id) {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "externaldrive.badge.checkmark")
                            }
                        }
                        .buttonStyle(.borderless)
                        .help(viewModel.strings.mount)
                        .disabled(workingVolumeIDs.contains(volume.id))
                        Button {
                            viewModel.beginEditing(volume)
                            openWindow(id: "volume-editor")
                            bringEditorForward()
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help(viewModel.strings.edit)
                        Button {
                            do {
                                try viewModel.delete(volume)
                                message = viewModel.strings.saved
                            } catch {
                                message = error.localizedDescription
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help(viewModel.strings.remove)
                    }
                    .padding(.vertical, 6)
                }
                .scrollContentBackground(.hidden)
            }

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(22)
        .background(.regularMaterial)
        .onAppear {
            viewModel.refreshAlerts()
        }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            viewModel.refreshAlerts()
        }
    }

    private func bringEditorForward() {
        [0.05, 0.2, 0.45].forEach { delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                focusEditorWindow()
            }
        }
    }

    private func focusEditorWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let editorWindow = NSApp.windows.first { $0.identifier?.rawValue == "volume-editor" }
        if let editorWindow {
            editorWindow.level = .floating
            editorWindow.orderFrontRegardless()
            editorWindow.makeKeyAndOrderFront(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @MainActor
    private func mount(_ volume: VolumeConfig) async {
        workingVolumeIDs.insert(volume.id)
        message = viewModel.strings.mounting
        do {
            message = try await viewModel.mountAsync(volume)
        } catch {
            message = error.localizedDescription
            viewModel.refreshAlerts()
        }
        workingVolumeIDs.remove(volume.id)
    }
}
