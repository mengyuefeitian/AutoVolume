import AppKit
import Sparkle
import AutoVolumeShared

/// Wraps Sparkle's standard updater: daily background checks plus the
/// "检查更新… / Check for Updates…" menu item. Download, EdDSA verification,
/// install and relaunch are Sparkle's own standard UI.
@MainActor
final class UpdateService: NSObject, @MainActor SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        controller.updater.automaticallyChecksForUpdates = UpdateSchedule.automaticallyChecks
        controller.updater.updateCheckInterval = UpdateSchedule.checkInterval
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // Menu-bar (LSUIElement) app: opt into gentle reminders so scheduled
    // checks surface the update window in front instead of behind other apps.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
