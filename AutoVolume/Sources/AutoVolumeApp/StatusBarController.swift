import AppKit
import SwiftUI
import AutoVolumeShared

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let viewModel: AppViewModel
    private let updateService: UpdateService
    private let editorController = EditorWindowController()
    private let settingsController = SettingsWindowController()

    init(viewModel: AppViewModel, updateService: UpdateService) {
        self.viewModel = viewModel
        self.updateService = updateService
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        configurePopover()
        AutoVolumeLogger.shared.info("Status bar controller started")
    }

    private static let idleStatusImageName = "externaldrive.connected.to.line.below"
    private static let workingStatusImageName = "arrow.triangle.2.circlepath"

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: Self.idleStatusImageName, accessibilityDescription: "AutoVolume")
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 620, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: ContentView(
                viewModel: viewModel,
                onAdd: { [weak self] in self?.showEditor(volume: nil) },
                onEdit: { [weak self] volume in self?.showEditor(volume: volume) },
                onWorkingChanged: { [weak self] isWorking in self?.setWorking(isWorking) }
            )
            .frame(width: 620, height: 520)
        )
    }

    /// Called on the main actor by `ContentView` whenever any volume is mounting/unmounting,
    /// so the status-item icon gives feedback even after the popover has closed (it closes the
    /// instant Mount/Unmount is clicked).
    private func setWorking(_ isWorking: Bool) {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: isWorking ? Self.workingStatusImageName : Self.idleStatusImageName,
            accessibilityDescription: "AutoVolume"
        )
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover(sender)
            return
        }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            viewModel.refreshAlertsOnly()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            AutoVolumeLogger.shared.info("Opened volume list")
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L10n.t(.menuViewLogs), action: #selector(openLogs), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L10n.t(.menuExportDiagnostics), action: #selector(exportDiagnostics), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L10n.t(.menuSettings), action: #selector(openSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L10n.t(.menuCheckForUpdates), action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.t(.menuQuit), action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items {
            item.target = self
        }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func showEditor(volume: VolumeConfig?) {
        AutoVolumeLogger.shared.info(volume == nil ? "Add button selected" : "Edit button selected for \(volume?.name ?? "")")
        popover.performClose(nil)
        let viewModel = viewModel
        DispatchQueue.main.async { [weak self] in
            self?.editorController.show(viewModel: viewModel, volume: volume)
        }
    }

    @objc private func openLogs() {
        do {
            try FileManager.default.createDirectory(at: AutoVolumeLogger.shared.logDirectoryURL, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: AutoVolumeLogger.shared.logFileURL.path) {
                AutoVolumeLogger.shared.info("Created log file")
            }
            NSWorkspace.shared.open(AutoVolumeLogger.shared.logDirectoryURL)
            AutoVolumeLogger.shared.info("Opened log directory")
        } catch {
            AutoVolumeLogger.shared.error("Open log directory failed: \(error.localizedDescription)")
        }
    }

    @objc private func exportDiagnostics() {
        AutoVolumeLogger.shared.info("Export diagnostics requested")
        let failureTitle = L10n.t(.alertExportDiagnosticsFailedTitle)
        let okTitle = L10n.t(.alertOk)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let exporter = DiagnosticsExporter(ntfsLogURL: AutoVolumeLogger.ntfs.logFileURL)
                let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                    ?? FileManager.default.homeDirectoryForCurrentUser
                let zip = try exporter.export(to: desktop)
                DispatchQueue.main.async {
                    AutoVolumeLogger.shared.info("Diagnostics exported to \(zip.path)")
                    NSWorkspace.shared.activateFileViewerSelecting([zip])
                }
            } catch {
                AutoVolumeLogger.shared.error("Export diagnostics failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = failureTitle
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: okTitle)
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            }
        }
    }

    @objc private func openSettings() {
        AutoVolumeLogger.shared.info("Opened settings")
        let viewModel = viewModel
        let updateService = updateService
        DispatchQueue.main.async { [weak self] in
            self?.settingsController.show(viewModel: viewModel, updateService: updateService)
        }
    }

    @objc private func checkForUpdates() {
        AutoVolumeLogger.shared.info("Check for updates requested")
        updateService.checkForUpdates()
    }

    @objc private func quit() {
        AutoVolumeLogger.shared.info("Quit requested from status menu")
        LaunchAgentInstaller.stop()
        NSApp.terminate(nil)
    }
}

@MainActor
private final class EditorWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var languageChangeObserver: NSObjectProtocol?

    override init() {
        super.init()
        languageChangeObserver = NotificationCenter.default.addObserver(
            forName: .autoVolumeLanguageChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.window?.title = L10n.t(.appProductName)
            }
        }
    }

    deinit {
        if let languageChangeObserver {
            NotificationCenter.default.removeObserver(languageChangeObserver)
        }
    }

    func show(viewModel: AppViewModel, volume: VolumeConfig?) {
        if let volume {
            viewModel.beginEditing(volume)
        } else {
            viewModel.beginAddingVolume()
        }
        EditorInputActivation.begin()

        let root = VolumeEditorView(
            viewModel: viewModel,
            volume: viewModel.editorVolume,
            onCancel: { [weak self] in self?.close() },
            onSaved: { message in AutoVolumeLogger.shared.info("Editor saved: \(message)") }
        )
        .id(viewModel.editorSessionID)
        .frame(width: 560, height: 430)

        let hostingController = NSHostingController(rootView: root)
        let editorWindow = window ?? NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        editorWindow.contentViewController = hostingController
        editorWindow.delegate = self
        editorWindow.identifier = NSUserInterfaceItemIdentifier("volume-editor")
        editorWindow.title = L10n.t(.appProductName)
        editorWindow.level = .floating
        editorWindow.collectionBehavior.formUnion([.fullScreenAuxiliary, .canJoinAllSpaces])
        editorWindow.hidesOnDeactivate = false
        editorWindow.isReleasedWhenClosed = false
        editorWindow.center()
        editorWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = editorWindow
        AutoVolumeLogger.shared.info(volume == nil ? "Opened add editor" : "Opened edit editor")
    }

    func close() {
        hide()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    private func hide() {
        window?.orderOut(nil)
        EditorInputActivation.end()
        AutoVolumeLogger.shared.info("Closed editor")
    }
}

@MainActor
private final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var languageChangeObserver: NSObjectProtocol?

    override init() {
        super.init()
        languageChangeObserver = NotificationCenter.default.addObserver(
            forName: .autoVolumeLanguageChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.window?.title = L10n.t(.menuSettings)
            }
        }
    }

    deinit {
        if let languageChangeObserver {
            NotificationCenter.default.removeObserver(languageChangeObserver)
        }
    }

    func show(viewModel: AppViewModel, updateService: UpdateService) {
        let root = SettingsView(viewModel: viewModel, updateService: updateService)
        let hostingController = NSHostingController(rootView: root)
        let settingsWindow = window ?? NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        settingsWindow.contentViewController = hostingController
        settingsWindow.delegate = self
        settingsWindow.identifier = NSUserInterfaceItemIdentifier("settings")
        settingsWindow.title = L10n.t(.menuSettings)
        settingsWindow.level = .floating
        settingsWindow.collectionBehavior.formUnion([.fullScreenAuxiliary, .canJoinAllSpaces])
        settingsWindow.hidesOnDeactivate = false
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.center()
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = settingsWindow
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window?.orderOut(nil)
        return false
    }
}
