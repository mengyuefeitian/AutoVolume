import SwiftUI
import AppKit

// Liquid Glass (macOS 26+) helpers. The app still deploys to macOS 14, so every use is gated with
// `#available`; older systems keep the previous material/bordered look.

extension View {
    /// Rounded Liquid Glass card on macOS 26+; unchanged on older systems.
    @ViewBuilder
    func liquidGlassCard(cornerRadius: CGFloat = 14) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self
        }
    }

    /// Glass button on macOS 26+ (prominent = tinted primary action), bordered buttons before that.
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }

    /// The pre-26 frosted background; on macOS 26+ the system's glass surface is used instead.
    @ViewBuilder
    func legacyMaterialBackground() -> some View {
        if #available(macOS 26.0, *) {
            self
        } else {
            self.background(.regularMaterial)
        }
    }
}

@MainActor
enum WindowPlacement {
    /// Centers `window` in the visible area (below the menu bar, above the Dock) of the screen the
    /// pointer is on, which is where the status-bar item that opened it lives.
    static func centerOnActiveScreen(_ window: NSWindow) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        window.layoutIfNeeded()
        var frame = window.frame
        frame.origin.x = (visible.midX - frame.width / 2).rounded()
        frame.origin.y = (visible.midY - frame.height / 2).rounded()
        window.setFrame(frame, display: true)
    }
}

@MainActor
enum GlassWindow {
    /// Content height added for the (transparent) title bar when content extends under it.
    static var titleBarInset: CGFloat {
        if #available(macOS 26.0, *) { return 28 } else { return 0 }
    }

    /// Puts `content` inside a Liquid Glass surface that fills the window (macOS 26+). Returns false on
    /// older systems so the caller keeps its regular content view controller.
    @discardableResult
    static func install(_ content: NSView, in window: NSWindow) -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        let glass = (window.contentView as? NSGlassEffectView) ?? NSGlassEffectView()
        glass.cornerRadius = 0
        glass.contentView = content
        window.contentView = glass
        return true
    }
}
