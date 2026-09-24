import SwiftUI
import AppKit
import Darwin
import AutoVolumeShared

@MainActor
let sharedAutoVolumeViewModel = AppViewModel()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var stallWatchdog: MainThreadStallWatchdog?
    private var updateService: UpdateService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AutoVolumeLogger.migrateLegacyLogIfNeeded()
        logEnvironmentLine()
        NSApp.setActivationPolicy(.accessory)
        // The watchdog must start before anything touches `sharedAutoVolumeViewModel` — that
        // global is lazily initialized on first access, and `AppViewModel.init` used to run a
        // synchronous, unbounded volume-status probe (up to ~3s per volume against a hung
        // WebDAV mount) with nothing watching the main thread for a stall until this point.
        let watchdog = MainThreadStallWatchdog()
        watchdog.start()
        stallWatchdog = watchdog
        applyStoredLanguage()
        let updateService = UpdateService()
        self.updateService = updateService
        statusBarController = StatusBarController(viewModel: sharedAutoVolumeViewModel, updateService: updateService)
        AutoVolumeLogger.shared.info("AutoVolume launched")
    }

    /// Loads persisted settings, migrates the legacy pre-`AppSettings.language`
    /// `UserDefaults` value if present, sets the active `L10n` language, and activates the
    /// `Bundle` localization swizzle — all before `UpdateService()` constructs Sparkle's
    /// updater, so Sparkle's own alerts pick up the right language from their first use.
    private func applyStoredLanguage() {
        let settingsStore = JSONAppSettingsStore()
        let loadedSettings = (try? settingsStore.load()) ?? AppSettings()
        let legacyLanguageValue = UserDefaults.standard.string(forKey: "AutoVolume.language")
        let settings: AppSettings
        if let migrated = LanguageMigration.migrate(settings: loadedSettings, legacyValue: legacyLanguageValue) {
            settings = migrated
            do {
                try settingsStore.save(migrated)
            } catch {
                AutoVolumeLogger.shared.error("Language migration save failed: \(error.localizedDescription)")
            }
        } else {
            settings = loadedSettings
        }
        L10n.setLanguage(settings.language)
        Bundle.activateLanguageOverride()
    }

    private func logEnvironmentLine() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "-"
        let build = info["CFBundleVersion"] as? String ?? "-"
        var systemInfo = utsname()
        uname(&systemInfo)
        let arch = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        AutoVolumeLogger.shared.info("Environment app=\(version)(\(build)) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString) arch=\(arch)")
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
