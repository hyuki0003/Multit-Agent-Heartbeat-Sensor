import AppKit
import HermesMonitorCore

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let summaryItem: NSMenuItem
    private let viewModel: MonitorViewModel
    private let toggleWindow: () -> Void

    init(viewModel: MonitorViewModel, toggleWindow: @escaping () -> Void) {
        self.viewModel = viewModel
        self.toggleWindow = toggleWindow
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.summaryItem = NSMenuItem(title: "0 running · 0 blocked", action: nil, keyEquivalent: "")
        super.init()
        configureStatusItem()
    }

    func update(snapshot: HermesMonitorSnapshot) {
        let running = snapshot.tasks.filter { $0.visualStatus == .running }.count
        let blocked = snapshot.tasks.filter { $0.visualStatus == .blocked }.count
        summaryItem.title = "\(running) running · \(blocked) blocked"
        statusItem.button?.toolTip = "Hermes Monitor — \(summaryItem.title)"
    }

    private func configureStatusItem() {
        let hotKey = MonitorPreferences.hotKey()
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "waveform.path.ecg",
                accessibilityDescription: "Hermes Monitor"
            )
            button.toolTip = "Hermes Monitor — 0 running · 0 blocked"
        }

        summaryItem.isEnabled = false
        let menu = NSMenu()
        menu.addItem(summaryItem)
        menu.addItem(.separator())
        menu.addItem(item(
            title: "Toggle Window (\(hotKey.displayName))",
            action: #selector(toggleWindowAction),
            keyEquivalent: hotKey.key.lowercased(),
            modifiers: modifierFlags(for: hotKey)
        ))
        menu.addItem(item(
            title: "Refresh Now",
            action: #selector(refreshNow),
            keyEquivalent: "r",
            modifiers: [.command]
        ))
        menu.addItem(item(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ",",
            modifiers: [.command]
        ))
        menu.addItem(.separator())
        menu.addItem(item(
            title: "Quit Hermes Monitor",
            action: #selector(quit),
            keyEquivalent: "q",
            modifiers: [.command]
        ))
        statusItem.menu = menu
    }

    private func modifierFlags(for hotKey: MonitorHotKeyPreference) -> NSEvent.ModifierFlags {
        var modifiers: NSEvent.ModifierFlags = []
        if hotKey.usesCommand { modifiers.insert(.command) }
        if hotKey.usesShift { modifiers.insert(.shift) }
        if hotKey.usesOption { modifiers.insert(.option) }
        if hotKey.usesControl { modifiers.insert(.control) }
        return modifiers
    }

    private func item(
        title: String,
        action: Selector,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        menuItem.keyEquivalentModifierMask = modifiers
        menuItem.target = self
        return menuItem
    }

    @objc private func toggleWindowAction() {
        toggleWindow()
    }

    @objc private func refreshNow() {
        Task { await viewModel.refresh() }
    }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: .showHermesMonitorSettings, object: nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
