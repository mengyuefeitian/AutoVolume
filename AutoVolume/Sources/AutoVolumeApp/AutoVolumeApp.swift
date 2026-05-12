import SwiftUI
import AutoVolumeShared

@main
struct AutoVolumeApp: App {
    @State private var viewModel = AppViewModel()

    var body: some Scene {
        MenuBarExtra("AutoVolume", systemImage: "externaldrive.connected.to.line.below") {
            ContentView(viewModel: viewModel)
                .frame(width: 520, height: 420)
        }
        .menuBarExtraStyle(.window)
    }
}
