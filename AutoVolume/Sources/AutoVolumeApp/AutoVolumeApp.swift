import SwiftUI
import AutoVolumeShared

@main
struct AutoVolumeApp: App {
    var body: some Scene {
        MenuBarExtra("AutoVolume", systemImage: "externaldrive.connected.to.line.below") {
            Text("AutoVolume")
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
