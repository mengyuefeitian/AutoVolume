import SwiftUI
import AutoVolumeShared

struct ContentView: View {
    @Bindable var viewModel: AppViewModel
    @State private var isPresentingEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("AutoVolume 智卷", systemImage: "externaldrive.connected.to.line.below")
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                Spacer()
                Button {
                    isPresentingEditor = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .keyboardShortcut("n")
            }

            if viewModel.volumes.isEmpty {
                ContentUnavailableView("No Volumes", systemImage: "externaldrive.badge.plus", description: Text("Add a network volume to keep it connected."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.volumes) { volume in
                    HStack {
                        Image(systemName: "externaldrive")
                        VStack(alignment: .leading) {
                            Text(volume.name).font(.headline)
                            Text("\(volume.protocolType.rawValue.uppercased()) · \(volume.server)/\(volume.remotePath)")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Int(volume.checkIntervalSeconds / 60))m")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .padding(22)
        .background(.regularMaterial)
        .sheet(isPresented: $isPresentingEditor) {
            VolumeEditorView(viewModel: viewModel)
        }
    }
}
