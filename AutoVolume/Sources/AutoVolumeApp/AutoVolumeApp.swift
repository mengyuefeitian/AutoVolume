import SwiftUI
import AppKit
import AutoVolumeShared

@MainActor
let sharedAutoVolumeViewModel = AppViewModel()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController(viewModel: sharedAutoVolumeViewModel)
        AutoVolumeLogger.shared.info("AutoVolume launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        AutoVolumeLogger.shared.info("AutoVolume terminating")
        LaunchAgentInstaller.stop()
    }
}

@main
struct AutoVolumeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        DispatchQueue.global(qos: .utility).async {
            LaunchAgentInstaller.installAndStart()
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
