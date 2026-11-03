import AppKit
import Sparkle
import AutoVolumeShared

/// Wraps Sparkle's standard updater: daily background checks plus the
/// "检查更新… / Check for Updates…" menu item. Download, EdDSA verification,
/// install and relaunch are Sparkle's own standard UI.
@MainActor
final class UpdateService: NSObject, @MainActor SPUStandardUserDriverDelegate, @MainActor SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    /// Ordered feeds baked into Info.plist (`AVUpdateFeedURLs`); empty falls back to `SUFeedURL`.
    private let feeds = UpdateFeeds.urls(fromInfo: Bundle.main.infoDictionary ?? [:])
    /// Feed chosen by the last probe; scheduled background checks use it between refreshes.
    private var activeFeed: URL?
    private var refreshTimer: Timer?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        controller.updater.automaticallyChecksForUpdates = UpdateSchedule.automaticallyChecks
        controller.updater.updateCheckInterval = UpdateSchedule.checkInterval
        refreshActiveFeed()
        // The app can run for days; re-pick so a feed that goes down (or comes back) is noticed.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshActiveFeed() }
        }
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        let feeds = feeds
        guard feeds.count > 1 else { controller.checkForUpdates(nil); return }
        // Probe first so the user-initiated check goes to a feed that is actually up.
        Task {
            let chosen = await Self.pickFeed(from: feeds)
            self.activeFeed = chosen
            self.controller.checkForUpdates(nil)
        }
    }

    private func refreshActiveFeed() {
        let feeds = feeds
        guard feeds.count > 1 else { return }
        Task { self.activeFeed = await Self.pickFeed(from: feeds) }
    }

    private nonisolated static func pickFeed(from feeds: [URL]) async -> URL? {
        await Task.detached { UpdateFeeds.select(from: feeds, isServing: { UpdateFeeds.isServingAppcast($0) }) }.value
    }

    /// Overrides `SUFeedURL`; nil keeps Sparkle's default (the primary feed).
    func feedURLString(for updater: SPUUpdater) -> String? {
        activeFeed?.absoluteString
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
