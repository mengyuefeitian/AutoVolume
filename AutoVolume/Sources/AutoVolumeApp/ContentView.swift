import SwiftUI
import AutoVolumeShared

struct ContentView: View {
    @Bindable var viewModel: AppViewModel
    @State private var message: String?
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
                Button {
                    viewModel.beginAddingVolume()
                    openWindow(id: "volume-editor")
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
                            do {
                                message = try viewModel.mount(volume)
                            } catch {
                                message = error.localizedDescription
                            }
                        } label: {
                            Image(systemName: "externaldrive.badge.checkmark")
                        }
                        .buttonStyle(.borderless)
                        .help(viewModel.strings.mount)
                        Button {
                            viewModel.beginEditing(volume)
                            openWindow(id: "volume-editor")
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
    }
}
