import SwiftUI
import AppKit
import AutoVolumeShared

struct ContentView: View {
    @Bindable var viewModel: AppViewModel
    let onAdd: () -> Void
    let onEdit: (VolumeConfig) -> Void
    var onWorkingChanged: (Bool) -> Void = { _ in }
    @State private var message: String?
    @State private var workingVolumeIDs: Set<VolumeConfig.ID> = []

    var body: some View {
        let _ = viewModel.languageRevision
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(L10n.t(.appProductName), systemImage: "externaldrive.connected.to.line.below")
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                Spacer()
                Menu {
                    if viewModel.alerts.isEmpty {
                        Text(L10n.t(.listNoAlerts))
                    } else {
                        ForEach(viewModel.alerts) { alert in
                            Text("\(alert.volumeName): \(alert.localizedMessage)")
                        }
                        Divider()
                        Button(L10n.t(.listClearAlerts)) {
                            Task {
                                await viewModel.clearAlertsAsync()
                            }
                        }
                    }
                } label: {
                    Label(L10n.t(.listAlerts), systemImage: viewModel.alerts.isEmpty ? "bell" : "exclamationmark.triangle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(viewModel.alerts.isEmpty ? Color.secondary : Color.orange)
                }
                .help(L10n.t(.listAlerts))
                Button {
                    hideListWindow()
                    onAdd()
                } label: {
                    Label(L10n.t(.listAdd), systemImage: "plus")
                }
                .keyboardShortcut("n")
            }

            if viewModel.volumes.isEmpty && viewModel.ntfsVolumes.isEmpty {
                ContentUnavailableView(L10n.t(.listEmptyTitle), systemImage: "externaldrive.badge.plus", description: Text(L10n.t(.listEmptyDescription)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                if !viewModel.ntfsVolumes.isEmpty {
                    Section {
                        ForEach(viewModel.ntfsVolumes) { ntfsVolume in
                            HStack(spacing: 12) {
                                Image(systemName: "externaldrive.fill.badge.checkmark")
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading) {
                                    Text(ntfsVolume.volumeName).font(.headline)
                                    Text(ntfsVolume.mountPoint)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(L10n.t(.listNtfsReadWriteBadge))
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
                ForEach(viewModel.volumes) { volume in
                    HStack(spacing: 12) {
                        Image(systemName: statusIcon(for: volume))
                            .foregroundStyle(statusColor(for: volume))
                        VStack(alignment: .leading) {
                            Text(volume.name).font(.headline)
                            Text("\(volume.protocolType.rawValue.uppercased()) · \(volume.server)/\(volume.remotePath)")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(L10n.t(.listIntervalMinutesShort, String(Int(volume.checkIntervalSeconds / 60))))
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
                        .help(L10n.t(.listMount))
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
                        .help(L10n.t(.listUnmount))
                        .disabled(workingVolumeIDs.contains(volume.id))
                        Button {
                            hideListWindow()
                            onEdit(volume)
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.t(.listEdit))
                        Button {
                            Task {
                                await delete(volume)
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.t(.listRemove))
                    }
                    .padding(.vertical, 6)
                }
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
            viewModel.refreshAlertsOnly()
        }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            viewModel.refreshAlertsOnly()
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
    private func delete(_ volume: VolumeConfig) async {
        do {
            try await viewModel.deleteAsync(volume)
            message = L10n.t(.statusSaved)
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor
    private func mount(_ volume: VolumeConfig) async {
        hideListWindow()
        setWorking(volume.id, isWorking: true)
        message = L10n.t(.statusMounting)
        do {
            message = try await viewModel.mountAsync(volume)
            setWorking(volume.id, isWorking: false)
        } catch {
            message = error.localizedDescription
            // Clear the progress indicator immediately on failure — don't hold it through the
            // several-second post-failure status refresh below.
            setWorking(volume.id, isWorking: false)
            await viewModel.refreshVolumeStatusesAsync()
        }
    }

    @MainActor
    private func unmount(_ volume: VolumeConfig) async {
        hideListWindow()
        setWorking(volume.id, isWorking: true)
        message = L10n.t(.statusUnmounting)
        do {
            try await viewModel.unmountAsync(volume)
            message = L10n.t(.statusUnmountSucceeded)
            setWorking(volume.id, isWorking: false)
        } catch {
            message = error.localizedDescription
            setWorking(volume.id, isWorking: false)
            await viewModel.refreshVolumeStatusesAsync()
        }
    }

    /// Keeps `workingVolumeIDs` (drives the per-row spinners) and the status-item's
    /// progress icon in sync. `hideListWindow()` closes the popover the instant Mount/Unmount
    /// is clicked, so without this the status-item icon is the only feedback the user gets
    /// during the several seconds a mount can take.
    @MainActor
    private func setWorking(_ id: VolumeConfig.ID, isWorking: Bool) {
        if isWorking {
            workingVolumeIDs.insert(id)
        } else {
            workingVolumeIDs.remove(id)
        }
        onWorkingChanged(!workingVolumeIDs.isEmpty)
    }
}
