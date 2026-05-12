import SwiftUI
import AutoVolumeShared

@main
struct AutoVolumeApp: App {
    @State private var viewModel = AppViewModel()

    var body: some Scene {
        MenuBarExtra(viewModel.productName, systemImage: "externaldrive.connected.to.line.below") {
            ContentView(viewModel: viewModel)
                .frame(width: 620, height: 520)
        }
        .menuBarExtraStyle(.window)
    }
}
