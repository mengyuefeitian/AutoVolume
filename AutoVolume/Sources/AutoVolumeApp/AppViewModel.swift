import Foundation
import Observation
import Darwin
import AutoVolumeShared

@Observable
public final class AppViewModel {
    public private(set) var volumes: [VolumeConfig] = []
    public private(set) var alerts: [VolumeAlert] = []
    public private(set) var volumeStatuses: [VolumeConfig.ID: VolumeStatus] = [:]
    public private(set) var ntfsVolumes: [NTFSVolume] = []
    public var selectedVolumeID: VolumeConfig.ID?
    public var editorVolume: VolumeConfig?
    public var editorSessionID = UUID()
    public private(set) var settings: AppSettings

    /// Bumped whenever `.autoVolumeLanguageChanged` fires. `@Observable` only tracks stored
    /// properties it sees read during a view's `body` evaluation, and `L10n.resolved` is a
    /// plain global, not a stored property of this class — reading it alone would never
    /// register as a SwiftUI dependency. Views read this property once in `body` (for example
    /// `let _ = viewModel.languageRevision`) purely to register the dependency; every other
    /// `L10n.t(...)` call in that `body` then re-resolves under the new language once SwiftUI
    /// re-evaluates the whole view.
    public private(set) var languageRevision = 0
    private var languageChangeObserver: NSObjectProtocol?

    /// The active language, backed by `settings.language`. The setter persists the change
    /// through `updateSettings` and propagates it to the shared `L10n` lookup (which drives
    /// this app's UI, the agent, and — via `Bundle.activateLanguageOverride()` — Sparkle's own
    /// alerts) so every consumer stays in sync with a single source of truth.
    public var language: AppLanguage {
        get { settings.language }
        set {
            guard newValue != settings.language else { return }
            let previousLanguage = settings.language
            // Flip `L10n` to the new language BEFORE persisting so that any SwiftUI
            // invalidation triggered by `updateSettings` (via `settings` changing) already
            // sees the new language when views next call `L10n.t(...)`. If the save then
            // fails, `settings` was never touched — revert `L10n` to match, so the app doesn't
            // end up displaying a language it didn't actually persist.
            L10n.setLanguage(newValue)
            var updatedSettings = settings
            updatedSettings.language = newValue
            let saved = updateSettings(updatedSettings)
            if !saved {
                L10n.setLanguage(previousLanguage)
                AutoVolumeLogger.shared.error("Language change to \(newValue.rawValue) could not be persisted; reverted to \(previousLanguage.rawValue)")
            }
        }
    }

    private let configStore: ConfigStore
    private let credentialStore: CredentialStore
    private let commandRunner: CommandRunner
    private let mountPlanner: MountPlanner
    private let connectivityTester: ConnectivityTester
    private let smbPreferencesWriter: SMBPreferencesWriter
    private let alertStore: AlertStore
    private let mountStateProvider: MountStateProvider
    private let mountExposure: MountExposure
    private let settingsStore: AppSettingsStore
    private let ntfsMountedVolumesStore = NTFSMountedVolumesStore()

    public init(
        configStore: ConfigStore = JSONConfigStore(),
        credentialStore: CredentialStore = EncryptedFileCredentialStore(),
        commandRunner: CommandRunner = ProcessCommandRunner(),
        mountPlanner: MountPlanner = MountPlanner(),
        connectivityTester: ConnectivityTester = ConnectivityTester(),
        smbPreferencesWriter: SMBPreferencesWriter = SMBPreferencesWriter(),
        alertStore: AlertStore = AlertStore(),
        mountStateProvider: MountStateProvider = FileSystemMountStateProvider(healthCheckTimeout: 3, validatesResponsiveness: true),
        mountExposure: MountExposure = MountExposure(),
        settingsStore: AppSettingsStore = JSONAppSettingsStore()
    ) {
        self.configStore = configStore
        self.credentialStore = credentialStore
        self.commandRunner = commandRunner
        self.mountPlanner = mountPlanner
        self.connectivityTester = connectivityTester
        self.smbPreferencesWriter = smbPreferencesWriter
        self.alertStore = alertStore
        self.mountStateProvider = mountStateProvider
        self.mountExposure = mountExposure
        self.settingsStore = settingsStore
        self.volumes = (try? configStore.load()) ?? []
        self.alerts = (try? alertStore.load()) ?? []
        self.settings = (try? settingsStore.load()) ?? AppSettings()
        migrateLegacyMountPoints()
        // Do not call the synchronous `refreshVolumeStatuses()` here: it probes every
        // configured volume's mount health (up to ~3s per volume, unbounded against a hung
        // WebDAV mount) and would block app launch on the main thread before the stall
        // watchdog even starts. Leave `volumeStatuses` empty at launch and populate it
        // asynchronously instead.
        Task { [weak self] in
            await self?.refreshVolumeStatusesAsync()
        }
        refreshNTFSVolumes()
        languageChangeObserver = NotificationCenter.default.addObserver(
            forName: .autoVolumeLanguageChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.languageRevision += 1
        }
    }

    deinit {
        if let languageChangeObserver {
            NotificationCenter.default.removeObserver(languageChangeObserver)
        }
    }

    public func beginAddingVolume() {
        editorVolume = nil
        editorSessionID = UUID()
    }

    public func beginEditing(_ config: VolumeConfig) {
        editorVolume = config
        editorSessionID = UUID()
    }

    public func password(for config: VolumeConfig?) -> String {
        guard let config else { return "" }
        return (try? credentialStore.password(for: config.id)) ?? ""
    }

    public func add(_ config: VolumeConfig, password: String?) throws {
        volumes.append(config)
        try persist()
        if let password, !password.isEmpty {
            try credentialStore.savePassword(password, for: config.id)
        }
        if config.protocolType == .smb {
            try smbPreferencesWriter.apply(options: config.smbOptions)
        }
        scheduleVolumeStatusRefresh()
    }

    public func save(_ config: VolumeConfig, password: String?) throws {
        if let index = volumes.firstIndex(where: { $0.id == config.id }) {
            volumes[index] = config
        } else {
            volumes.append(config)
        }
        try persist()
        if let password, !password.isEmpty {
            try credentialStore.savePassword(password, for: config.id)
        }
        scheduleVolumeStatusRefresh()
    }

    /// Kicks off `refreshVolumeStatusesAsync()` without blocking the caller. `add`/`save` are
    /// synchronous, main-thread APIs (called directly from UI actions), but the refresh itself
    /// probes every volume's mount health — up to ~3s per volume — so it must never run inline
    /// on main. `@MainActor` on `refreshVolumeStatusesAsync()` means the snapshot of `volumes`
    /// it takes still reflects the state just persisted above.
    private func scheduleVolumeStatusRefresh() {
        Task { [weak self] in
            await self?.refreshVolumeStatusesAsync()
        }
    }

    public func delete(_ config: VolumeConfig) throws {
        volumes.removeAll { $0.id == config.id }
        try persist()
        try credentialStore.deletePassword(for: config.id)
        try? alertStore.resolve(volumeID: config.id)
    }

    /// Deletes the volume, then refreshes alerts/statuses off-main. `delete(_:)` itself is
    /// cheap (JSON + keychain writes), but the follow-up status refresh probes every
    /// remaining volume's mount health (subprocess calls with multi-second timeouts) and
    /// must never run on the main thread — see `refreshVolumeStatusesAsync()`.
    @MainActor
    public func deleteAsync(_ config: VolumeConfig) async throws {
        try delete(config)
        await refreshVolumeStatusesAsync()
    }

    /// Persists `newSettings` and, only on success, applies it to `settings`. Returns whether
    /// the save succeeded so callers that layer additional state on top of a settings change
    /// (notably the `language` setter, which also flips the global `L10n` language) can revert
    /// that additional state instead of leaving the app out of sync with what's on disk.
    @discardableResult
    public func updateSettings(_ newSettings: AppSettings) -> Bool {
        do {
            try settingsStore.save(newSettings)
            settings = newSettings
            AutoVolumeLogger.shared.info("Settings updated: logLevel=\(newSettings.logLevel), openFinderAfterMount=\(newSettings.openFinderAfterMount)")
            return true
        } catch {
            AutoVolumeLogger.shared.error("Settings save failed: \(error.localizedDescription)")
            return false
        }
    }

    public func refreshAlerts() {
        alerts = (try? alertStore.load()) ?? []
        refreshVolumeStatuses()
    }

    public func refreshAlertsOnly() {
        alerts = (try? alertStore.load()) ?? []
        refreshNTFSVolumes()
    }

    public func refreshNTFSVolumes() {
        ntfsVolumes = (try? ntfsMountedVolumesStore.load()) ?? []
    }

    public func clearAlerts() {
        try? alertStore.clear()
        alerts = []
    }

    /// Clears the alert store (cheap), then recomputes volume statuses off-main. `clearAlerts()`
    /// was previously invoked directly from a `Menu` `Button` on the main thread and, via
    /// `refreshAlerts()` → `refreshVolumeStatuses()`, ran the full `PathHealthProbe` loop
    /// (~3s per volume against a hung mount) synchronously on main — this is the async
    /// replacement, matching the `deleteAsync`/`refreshVolumeStatusesAsync` pattern.
    @MainActor
    public func clearAlertsAsync() async {
        clearAlerts()
        await refreshVolumeStatusesAsync()
    }

    /// Pure computation over the given snapshot — no access to `self`, safe to run off-main.
    public static func computeVolumeStatuses(
        volumes: [VolumeConfig],
        alerts: [VolumeAlert],
        mountStateProvider: MountStateProvider
    ) -> [VolumeConfig.ID: VolumeStatus] {
        var statuses: [VolumeConfig.ID: VolumeStatus] = [:]
        for volume in volumes {
            if mountStateProvider.isMounted(config: volume) {
                statuses[volume.id] = .mounted
            } else if let alert = alerts.first(where: { $0.volumeID == volume.id }) {
                statuses[volume.id] = .failed(message: alert.message)
            } else {
                statuses[volume.id] = .unmounted
            }
        }
        return statuses
    }

    /// Synchronous variant for callers already confirmed to be on the main thread outside a
    /// mount/unmount flow (init, add, save, clearAlerts). Each call to `isMounted` can spawn a
    /// subprocess with a multi-second timeout, so this must never be called from a background
    /// thread or from inside mount/unmount — use `refreshVolumeStatusesAsync()` there instead.
    public func refreshVolumeStatuses() {
        volumeStatuses = Self.computeVolumeStatuses(volumes: volumes, alerts: alerts, mountStateProvider: mountStateProvider)
    }

    /// Reloads alerts and recomputes volume statuses off the calling thread, then assigns both
    /// observable properties back on the `MainActor`. Safe to call from any context — mount/
    /// unmount (running on a detached background task) and UI-driven flows (already on the
    /// main actor) both need the actual probing to happen off-main. `@MainActor` guarantees
    /// `volumes` is read on main before being handed to the detached probe, and — since this
    /// function is itself main-actor-isolated — execution automatically resumes on main after
    /// `await`ing the detached task, so no explicit `MainActor.run` hop is needed to assign the
    /// results back.
    @MainActor
    public func refreshVolumeStatusesAsync() async {
        let volumesSnapshot = volumes
        let provider = mountStateProvider
        let alertStore = alertStore
        let (loadedAlerts, statuses) = await Task.detached {
            let loadedAlerts = (try? alertStore.load()) ?? []
            let statuses = Self.computeVolumeStatuses(volumes: volumesSnapshot, alerts: loadedAlerts, mountStateProvider: provider)
            return (loadedAlerts, statuses)
        }.value
        self.alerts = loadedAlerts
        self.volumeStatuses = statuses
    }

    public func testConnection(_ config: VolumeConfig, password: String?) throws -> String {
        AutoVolumeLogger.shared.info("Testing connection for \(config.name) \(config.protocolType.rawValue)")
        if config.protocolType == .webdav {
            try verifyConnectivity(for: config, password: password, fallbackKey: .errorCommandConnectionTestFailed)
            AutoVolumeLogger.shared.info("Connection test passed for \(config.name)")
            return L10n.t(.statusTestSucceeded)
        }

        let result = try runTemporaryMountTest(for: config, password: password)
        guard result.exitCode == 0 else {
            AutoVolumeLogger.shared.warning("Connection test failed for \(config.name): \(commandFailureMessage(result, fallbackKey: .errorCommandConnectionTestFailed))")
            throw AppViewModelError.commandFailed(commandFailureMessage(result, fallbackKey: .errorCommandConnectionTestFailed))
        }
        AutoVolumeLogger.shared.info("Connection test passed for \(config.name)")
        return L10n.t(.statusTestSucceeded)
    }

    public func testConnectionAsync(_ config: VolumeConfig, password: String?) async throws -> String {
        try await Task.detached {
            try self.testConnection(config, password: password)
        }.value
    }

    public func mount(_ config: VolumeConfig, password: String? = nil) async throws -> String {
        AutoVolumeLogger.shared.info("Mount requested for \(config.name) \(config.protocolType.rawValue)")
        let operationName = "\(config.protocolType.rawValue)-mount \(config.name)"
        DiagnosticsContext.shared.begin(operationName)
        defer { DiagnosticsContext.shared.end() }
        let timer = PhaseTimer(operation: operationName)
        do {
            let storedPassword = try password ?? credentialStore.password(for: config.id)
            if config.protocolType == .smb {
                try smbPreferencesWriter.apply(options: config.smbOptions)
            }
            try await runMountCommand(for: config, password: storedPassword, timer: timer)
            if mountPlanner.shouldOpenFinderAfterMount(for: config) {
                let openResult = try openMountedVolume(config, timer: timer)
                if openResult.exitCode != 0 {
                    AutoVolumeLogger.shared.warning("Finder open failed for \(config.name): \(commandFailureMessage(openResult, fallbackKey: .errorCommandFinderFailed))")
                    throw AppViewModelError.commandFailed(finderOpenFailureMessage(openResult))
                }
            }
            AutoVolumeLogger.shared.info("Mount succeeded for \(config.name)")
            timer.finish(result: "success")
            return L10n.t(.statusMountSucceeded)
        } catch {
            timer.finish(result: "failed: \(error.localizedDescription)")
            throw error
        }
    }

    public func mountAsync(_ config: VolumeConfig, password: String? = nil) async throws -> String {
        try await Task.detached {
            try await self.mount(config, password: password)
        }.value
    }

    public func saveAsync(_ config: VolumeConfig, password: String?) async throws {
        try save(config, password: password)
    }

    public func unmount(_ config: VolumeConfig) async throws {
        AutoVolumeLogger.shared.info("Unmount requested for \(config.name)")
        let operationName = "\(config.protocolType.rawValue)-unmount \(config.name)"
        DiagnosticsContext.shared.begin(operationName)
        defer { DiagnosticsContext.shared.end() }
        let mountPoint = mountPlanner.unmountTarget(for: config)
        let result = try commandRunner.run(mountPlanner.unmountPlan(mountPoint: mountPoint))
        guard result.exitCode == 0 else {
            let forceResult = try commandRunner.run(mountPlanner.forceUnmountPlan(mountPoint: mountPoint))
            if forceResult.exitCode != 0 {
                AutoVolumeLogger.shared.warning("Unmount failed for \(config.name): \(commandFailureMessage(forceResult, fallbackKey: .errorCommandUnmountFailed))")
                throw AppViewModelError.commandFailed(commandFailureMessage(forceResult, fallbackKey: .errorCommandUnmountFailed))
            }
            await refreshVolumeStatusesAsync()
            AutoVolumeLogger.shared.info("Force unmount succeeded for \(config.name)")
            return
        }
        await refreshVolumeStatusesAsync()
        AutoVolumeLogger.shared.info("Unmount succeeded for \(config.name)")
    }

    public func unmountAsync(_ config: VolumeConfig) async throws {
        try await Task.detached {
            try await self.unmount(config)
        }.value
    }

    private func persist() throws {
        try configStore.save(volumes)
    }

    private func migrateLegacyMountPoints() {
        let root = Self.defaultMountRoot
        var didChange = false
        for index in volumes.indices {
            let mountPoint = volumes[index].mountPoint.trimmingCharacters(in: .whitespacesAndNewlines)
            if mountPoint == root || mountPoint == root + "/" {
                volumes[index].mountPoint = Self.defaultMountPoint(for: volumes[index].name)
                didChange = true
            }
        }
        if didChange {
            try? persist()
        }
    }

    private static var defaultMountRoot: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Volumes", isDirectory: true)
            .path
    }

    public static func defaultMountPoint(for name: String) -> String {
        let fallback = "AutoVolume"
        let sanitizedName = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        return URL(fileURLWithPath: defaultMountRoot)
            .appendingPathComponent(sanitizedName.isEmpty ? fallback : sanitizedName, isDirectory: true)
            .path
    }

    private func runMountCommand(for config: VolumeConfig, password: String?, timer: PhaseTimer) async throws {
        if config.protocolType == .webdav {
            try verifyConnectivity(for: config, password: password, fallbackKey: .errorCommandMountFailed)
        }
        timer.mark("connectivity")
        try mountExposure.prepare(config: config, planner: mountPlanner)
        timer.mark("prepare")
        let result = try runMountWithRecovery(for: config, password: password, timer: timer)
        guard result.exitCode == 0 else {
            throw AppViewModelError.commandFailed(mountFailureMessage(for: config, result: result))
        }
        // `expose()` only (re)creates a local symlink at the visible mount point; it does not
        // change the health-check target (`MountPlanner.healthCheckPath` already resolves the
        // SMB subpath before this runs), so re-probing responsiveness here would just repeat
        // the check `runMountWithRecovery` already performed via `waitForMountedVolumeResponse`.
        try mountExposure.expose(config: config, planner: mountPlanner)
        timer.mark("expose")
        try? alertStore.resolve(volumeID: config.id)
        await refreshVolumeStatusesAsync()
        timer.mark("refresh")
    }

    private func verifyConnectivity(for config: VolumeConfig, password: String?, fallbackKey: L10nKey) throws {
        let plan = try connectivityTester.testPlan(for: config, password: password)
        let result = try commandRunner.run(plan).redacting(secrets: [password])
        let connectivity = connectivityTester.checkResult(for: config, result: result)
        guard connectivity.isReachable else {
            let localizedMessage = connectivity.messageKey.map { L10n.t($0, args: connectivity.messageArgs) }
                ?? connectivity.message
                ?? commandFailureMessage(result, fallbackKey: fallbackKey)
            throw AppViewModelError.commandFailed(localizedMessage)
        }
    }

    private func openMountedVolume(_ config: VolumeConfig, timer: PhaseTimer) throws -> CommandResult {
        let browsePath = mountPlanner.resolvedBrowsePath(for: config)
        Thread.sleep(forTimeInterval: 0.6)
        guard PathHealthProbe(timeout: 3).isResponsive(path: browsePath) else {
            return CommandResult(exitCode: 1, stdout: "", stderr: L10n.t(.errorFinderNotResponding, browsePath))
        }
        cleanupFinderWindows(for: config, resolvedBrowsePath: browsePath)
        timer.mark("finder-cleanup")
        let result = try commandRunner.run(mountPlanner.finderRevealPlan(for: config, resolvedBrowsePath: browsePath))
        timer.mark("finder-open")
        return result
    }

    private func cleanupFinderWindows(for config: VolumeConfig, resolvedBrowsePath: String) {
        let paths = mountPlanner.finderCleanupPaths(for: config, resolvedBrowsePath: resolvedBrowsePath)
        guard !paths.isEmpty else { return }
        // Finder can be slow or unresponsive (this is the exact class of stall this task
        // fixes), so skip the full cleanup script entirely unless a Finder window is actually
        // targeting one of our paths, and bound every osascript call with a wall-clock kill —
        // `CommandRunner` has no timeout of its own, so this bypasses it and spawns the
        // process directly, reusing PathHealthProbe's timeout+kill pattern.
        guard finderHasWindowTargeting(paths) else { return }
        let script = """
        with timeout of 3 seconds
            tell application "Finder"
                repeat with windowPath in {\(paths.map { "\"\(Self.appleScriptEscaped($0))\"" }.joined(separator: ", "))}
                    repeat with finderWindow in windows
                        try
                            if POSIX path of (target of finderWindow as alias) is (windowPath as text) then
                                close finderWindow
                            end if
                        end try
                    end repeat
                end repeat
            end tell
        end timeout
        """
        _ = runAppleScriptWithTimeout(script, timeout: 5)
    }

    private func finderHasWindowTargeting(_ paths: [String]) -> Bool {
        // `POSIX path of (target of every Finder window as alias list)` raises -1728 as soon as
        // any single window's target can't coerce to an alias (e.g. Recents) or there are 2+
        // windows open, and the outer `try` swallows that for the *whole* list — so cleanup was
        // always skipped whenever it mattered. Loop per window instead, with its own `try`, so
        // one bad window doesn't blank out every other window's path.
        let script = """
        tell application "Finder"
            with timeout of 3 seconds
                set out to ""
                repeat with w in every Finder window
                    try
                        set out to out & POSIX path of (target of w as alias) & linefeed
                    end try
                end repeat
                return out
            end timeout
        end tell
        """
        guard let result = runAppleScriptWithTimeout(script, timeout: 5), result.exitCode == 0 else {
            // If the fast probe itself fails or times out, skip the full cleanup rather than
            // risk running it against a Finder that is already unresponsive.
            return false
        }
        // Finder returns directory paths with a trailing "/"; tolerate that difference against
        // our candidate paths, which don't carry one.
        let windowPaths = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : String($0) }
        return paths.contains { candidate in
            windowPaths.contains { $0 == candidate }
        }
    }

    /// Runs an AppleScript via osascript with a hard wall-clock timeout, bypassing the
    /// injected `commandRunner` (which has no timeout support). Mirrors `PathHealthProbe`'s
    /// wait-with-timeout-then-kill pattern in MountState.swift.
    private func runAppleScriptWithTimeout(_ script: String, timeout: TimeInterval) -> CommandResult? {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin

        do {
            try process.run()
        } catch {
            return nil
        }
        stdin.fileHandleForWriting.write(Data(script.utf8))
        try? stdin.fileHandleForWriting.close()

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            group.leave()
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            return nil
        }
        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private func runTemporaryMountTest(for config: VolumeConfig, password: String?) throws -> CommandResult {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoVolumeConnectionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let testMountPoint = testRoot.appendingPathComponent(config.name.isEmpty ? "Volume" : config.name, isDirectory: true).path
        let testConfig = VolumeConfig(
            id: config.id,
            name: config.name,
            protocolType: config.protocolType,
            server: config.server,
            remotePath: config.remotePath,
            username: config.username,
            mountPoint: testMountPoint,
            checkIntervalSeconds: config.checkIntervalSeconds,
            isEnabled: config.isEnabled,
            smbOptions: config.smbOptions
        )
        defer {
            let mountPoint = mountPlanner.effectiveMountPoint(for: testConfig)
            _ = try? commandRunner.run(mountPlanner.unmountPlan(mountPoint: mountPoint))
            _ = try? commandRunner.run(mountPlanner.forceUnmountPlan(mountPoint: mountPoint))
            try? FileManager.default.removeItem(at: testRoot)
        }

        try mountExposure.prepare(config: testConfig, planner: mountPlanner)
        let timer = PhaseTimer(operation: "\(testConfig.protocolType.rawValue)-test \(testConfig.name)")
        let result = try runMountWithRecovery(for: testConfig, password: password, timer: timer)
        guard result.exitCode == 0 else { return result }
        try mountExposure.expose(config: testConfig, planner: mountPlanner)
        let probePath = mountPlanner.exposedPathTarget(for: testConfig) ?? mountPlanner.effectiveMountPoint(for: testConfig)
        guard PathHealthProbe(timeout: 5).isResponsive(path: probePath) else {
            return CommandResult(exitCode: 1, stdout: "", stderr: L10n.t(.errorMountVolumeNotRespondingAtRemotePath))
        }
        return result
    }

    private func runMountWithRecovery(for config: VolumeConfig, password: String?, timer: PhaseTimer) throws -> CommandResult {
        let plan = try mountPlanner.mountPlan(for: config, password: password, suppressesUserInterface: true)
        let result = try commandRunner.run(plan).redacting(secrets: [password])
        timer.mark("mount-command")
        logMountCommandResult(result, config: config)
        if result.exitCode == 0 {
            // `mark` logs elapsed time since the *previous* mark, so it must be called
            // after the phase it names has actually run — not before, which would fold
            // the phase's own duration into whatever comes next instead.
            let isStale = mountedVolumeIsStale(config)
            timer.mark("stale-check")
            guard !isStale else {
                unmountStaleTarget(for: config)
                let retryResult = try commandRunner.run(plan).redacting(secrets: [password])
                timer.mark("mount-command")
                logMountCommandResult(retryResult, config: config)
                guard retryResult.exitCode == 0 else { return retryResult }
                let responded = waitForMountedVolumeResponse(config)
                timer.mark("response-wait")
                return responded
                    ? retryResult
                    : CommandResult(exitCode: 1, stdout: retryResult.stdout, stderr: L10n.t(.errorMountVolumeNotRespondingAfterStaleClear))
            }
            let responded = waitForMountedVolumeResponse(config)
            timer.mark("response-wait")
            return responded
                ? result
                : CommandResult(exitCode: 1, stdout: result.stdout, stderr: L10n.t(.errorMountVolumeNotResponding))
        }

        guard isOccupiedMountPointError(result) else {
            return result
        }

        unmountStaleTarget(for: config)
        let retryResult = try commandRunner.run(plan).redacting(secrets: [password])
        timer.mark("mount-command")
        logMountCommandResult(retryResult, config: config)
        guard retryResult.exitCode == 0 else { return retryResult }
        let responded = waitForMountedVolumeResponse(config)
        timer.mark("response-wait")
        return responded
            ? retryResult
            : CommandResult(exitCode: 1, stdout: retryResult.stdout, stderr: L10n.t(.errorMountVolumeNotRespondingAfterOccupiedClear))
    }

    /// Logs the osascript mount command's exit code and redacted stderr for every attempt,
    /// including successful ones — needed to diagnose a stall that happens *after* the
    /// mount command itself already returned.
    private func logMountCommandResult(_ result: CommandResult, config: VolumeConfig) {
        AutoVolumeLogger.shared.info("\(config.protocolType.rawValue)-mount \(config.name) osascript exitCode=\(result.exitCode) stderr=\(CommandResult.redacted(result.stderr))")
    }

    private func waitForMountedVolumeResponse(_ config: VolumeConfig) -> Bool {
        for attempt in 0..<3 {
            if mountedVolumeIsResponsive(config) {
                return true
            }
            if attempt < 2 {
                Thread.sleep(forTimeInterval: 0.8)
            }
        }
        return false
    }

    private func mountedVolumeIsStale(_ config: VolumeConfig) -> Bool {
        SystemMountTable().contains(config: config) && !mountedVolumeIsResponsive(config)
    }

    private func mountedVolumeIsResponsive(_ config: VolumeConfig) -> Bool {
        PathHealthProbe(timeout: 3).isResponsive(path: mountPlanner.healthCheckPath(for: config))
    }

    private func unmountStaleTarget(for config: VolumeConfig) {
        let mountPoint = mountPlanner.unmountTarget(for: config)
        _ = try? commandRunner.run(mountPlanner.unmountPlan(mountPoint: mountPoint))
        _ = try? commandRunner.run(mountPlanner.forceUnmountPlan(mountPoint: mountPoint))
    }

    private func isOccupiedMountPointError(_ result: CommandResult) -> Bool {
        let message = "\(result.stdout)\n\(result.stderr)".lowercased()
        return message.contains("file exists") || message.contains("resource busy") || message.contains("already mounted")
    }

    /// `detail` is either real subprocess stderr/stdout (untranslated, per design) or a string
    /// this app already synthesized via `L10n.t(...)` at its construction site (for example the
    /// "volume did not respond" messages below) — either way it is passed through verbatim.
    /// Only the generic fallback, when there's no detail at all, is localized here.
    private func commandFailureMessage(_ result: CommandResult, fallbackKey: L10nKey) -> String {
        let detail = result.stderr.isEmpty ? result.stdout : result.stderr
        if detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.t(fallbackKey, String(result.exitCode))
        }
        return detail
    }

    private func mountFailureMessage(for config: VolumeConfig, result: CommandResult) -> String {
        let detail = result.stderr.isEmpty ? result.stdout : result.stderr
        if config.protocolType == .webdav, detail.contains("-5014") {
            return L10n.t(.errorMountWebdavFinder5014)
        }
        if config.protocolType == .webdav, result.exitCode == 22 {
            return L10n.t(.errorMountWebdavExit22)
        }
        return commandFailureMessage(result, fallbackKey: .errorCommandMountFailed)
    }

    private func finderOpenFailureMessage(_ result: CommandResult) -> String {
        let detail = commandFailureMessage(result, fallbackKey: .errorCommandFinderFailed)
        return L10n.t(.errorFinderOpenFailed, detail)
    }

    private static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

}

enum AppViewModelError: Error, LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            message.isEmpty ? L10n.t(.errorCommandGenericFailed) : message
        }
    }
}
