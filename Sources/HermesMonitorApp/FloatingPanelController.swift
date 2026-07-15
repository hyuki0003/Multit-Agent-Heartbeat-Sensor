import AppKit
import SwiftUI

extension Notification.Name {
    static let toggleHermesMonitorPanel = Notification.Name("toggleHermesMonitorPanel")
}

@MainActor
final class FloatingPanelController {
    private let panel: FloatingMonitorPanel

    init<Content: View>(rootView: Content) {
        let initialFrame = NSRect(x: 0, y: 0, width: 430, height: 720)
        panel = FloatingMonitorPanel(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: rootView)
        panel.title = "Hermes Monitor"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = NSSize(width: 360, height: 460)
        let autosaveName = "HermesMonitor.FloatingPanel"
        let restoredFrame = panel.setFrameUsingName(autosaveName)
        _ = panel.setFrameAutosaveName(autosaveName)
        if !restoredFrame {
            dockOnRight()
        }
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func dockOnRight() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.maxX - panel.frame.width - 16,
            y: visible.midY - panel.frame.height / 2
        )
        panel.setFrameOrigin(origin)
    }
}

final class FloatingMonitorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
