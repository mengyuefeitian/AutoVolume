import AppKit
import SwiftUI
import AutoVolumeShared

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let viewModel: AppViewModel
    private let editorController = EditorWindowController()

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        configurePopover()
        AutoVolumeLogger.shared.info("Status bar controller started")
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: "AutoVolume")
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
                onEdit: { [weak self] volume in self?.showEditor(volume: volume) }
            )
            .frame(width: 620, height: 520)
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
        menu.addItem(NSMenuItem(title: localized("查看日志", "View Logs"), action: #selector(openLogs), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: localized("关于", "About"), action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: localized("退出", "Quit"), action: #selector(quit), keyEquivalent: "q"))
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

    @objc private func showAbout() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "-"
        let build = info["CFBundleVersion"] as? String ?? "-"
        let alert = NSAlert()
        alert.messageText = "AutoVolume（智卷）"
        alert.informativeText = "\(localized("版本", "Version")) \(version) (\(build))"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        AutoVolumeLogger.shared.info("Opened about dialog")
    }

    @objc private func quit() {
        AutoVolumeLogger.shared.info("Quit requested from status menu")
        LaunchAgentInstaller.stop()
        NSApp.terminate(nil)
    }

    private func localized(_ chinese: String, _ english: String) -> String {
        viewModel.language == .chinese ? chinese : english
    }
}

@MainActor
private final class EditorWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

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
        editorWindow.title = viewModel.productName
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
