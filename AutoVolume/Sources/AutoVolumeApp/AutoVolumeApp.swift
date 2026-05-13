import SwiftUI
import AutoVolumeShared

@main
struct AutoVolumeApp: App {
    @State private var viewModel = AppViewModel()

    init() {
        DispatchQueue.global(qos: .utility).async {
            LaunchAgentInstaller.installAndStart()
        }
    }

    var body: some Scene {
        MenuBarExtra(viewModel.productName, systemImage: "externaldrive.connected.to.line.below") {
            ContentView(viewModel: viewModel)
                .frame(width: 620, height: 520)
        }
        .menuBarExtraStyle(.window)

        Window(viewModel.productName, id: "volume-editor") {
            VolumeEditorView(
                viewModel: viewModel,
                volume: viewModel.editorVolume,
                onCancel: {},
                onSaved: { _ in }
            )
            .id(viewModel.editorSessionID)
            .frame(width: 560, height: 430)
        }
        .defaultSize(width: 560, height: 430)
    }
}
