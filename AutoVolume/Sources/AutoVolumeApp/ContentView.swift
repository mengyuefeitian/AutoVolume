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
                    hideListWindow()
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
                        Image(systemName: statusIcon(for: volume))
                            .foregroundStyle(statusColor(for: volume))
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
                            Task {
                                await unmount(volume)
                            }
                        } label: {
                            if workingVolumeIDs.contains(volume.id) {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "eject.circle")
                            }
                        }
                        .buttonStyle(.borderless)
                        .help(viewModel.strings.unmount)
                        .disabled(workingVolumeIDs.contains(volume.id))
                        Button {
                            hideListWindow()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            focusEditorWindow()
        }
    }

    private func focusEditorWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let editorWindow = NSApp.windows.first { $0.identifier?.rawValue == "volume-editor" }
        if let editorWindow {
            editorWindow.level = .floating
            editorWindow.collectionBehavior.formUnion([.fullScreenAuxiliary, .canJoinAllSpaces])
            editorWindow.hidesOnDeactivate = false
            editorWindow.makeKeyAndOrderFront(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func hideListWindow() {
        DispatchQueue.main.async {
            NSApp.windows
                .filter { $0.identifier?.rawValue != "volume-editor" }
                .forEach { $0.orderOut(nil) }
        }
    }

    private func statusIcon(for volume: VolumeConfig) -> String {
        switch viewModel.volumeStatuses[volume.id] {
        case .mounted:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        default:
            return "circle"
        }
    }

    private func statusColor(for volume: VolumeConfig) -> Color {
        switch viewModel.volumeStatuses[volume.id] {
        case .mounted:
            return .green
        case .failed:
            return .red
        default:
            return .secondary
        }
    }

    @MainActor
    private func mount(_ volume: VolumeConfig) async {
        hideListWindow()
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

    @MainActor
    private func unmount(_ volume: VolumeConfig) async {
        hideListWindow()
        workingVolumeIDs.insert(volume.id)
        message = viewModel.strings.unmounting
        do {
            try await viewModel.unmountAsync(volume)
            message = viewModel.strings.unmountSucceeded
        } catch {
            message = error.localizedDescription
            viewModel.refreshAlerts()
        }
        workingVolumeIDs.remove(volume.id)
    }
}
