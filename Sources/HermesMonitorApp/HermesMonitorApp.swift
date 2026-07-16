#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
#if canImport(HermesMonitorCore)
import HermesMonitorCore
#endif
import SwiftUI

@main
enum HermesMonitorApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = HermesMonitorAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class HermesMonitorAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panelController: FloatingPanelController?
    private var viewModel: MonitorViewModel?
    private var hotKeyController: GlobalHotKeyController?
    private var menuBarController: MenuBarController?
    private var notificationController: TaskNotificationController?
    private var settingsWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[HermesMonitor] applicationDidFinishLaunching START")

        let model: MonitorViewModel
        do {
            let client = try MonitorConnectionSettings.load().makeClient()
            model = MonitorViewModel(client: client)
        } catch {
            model = MonitorViewModel(client: nil, initialError: error.localizedDescription)
        }

        viewModel = model
        panelController = FloatingPanelController(rootView: MonitorRootView(viewModel: model))
        menuBarController = MenuBarController(viewModel: model) { [weak self] in
            self?.panelController?.toggle()
        }
        if NotificationAvailabilityPolicy.isAvailable(
            processBundleURL: Bundle.main.bundleURL,
            bundleIdentifier: Bundle.main.bundleIdentifier
        ) {
            notificationController = TaskNotificationController { [weak self] taskID in
                self?.viewModel?.selectTask(taskID)
                self?.panelController?.show()
            }
            notificationController?.requestAuthorization()
        }
        model.onSnapshot = { [weak self] snapshot in
            self?.menuBarController?.update(snapshot: snapshot)
            self?.notificationController?.process(
                snapshot: snapshot,
                preferences: MonitorPreferences.notifications()
            )
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTogglePanel(_:)),
            name: .toggleHermesMonitorPanel,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSettings(_:)),
            name: .showHermesMonitorSettings,
            object: nil
        )
        let hotKey = GlobalHotKeyController {
            NotificationCenter.default.post(name: .toggleHermesMonitorPanel, object: nil)
        }
        do {
            try hotKey.register()
            hotKeyController = hotKey
        } catch {
            model.reportNonfatalError(error)
        }
        model.startMonitoring {
            MonitorPreferences.refreshInterval()
        }

        // Show the floating panel on launch — this is the main UI.
        NSLog("[HermesMonitor] About to show panel")
        panelController?.show()
        NSLog("[HermesMonitor] applicationDidFinishLaunching DONE")
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel?.stopMonitoring()
        hotKeyController = nil
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        panelController?.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func handleTogglePanel(_ notification: Notification) {
        panelController?.toggle()
    }

    @objc private func handleShowSettings(_ notification: Notification) {
        showSettings()
    }

    // MARK: - Settings Window

    func showSettings() {
        if settingsWindowController == nil {
            let hostingController = NSHostingController(rootView: MonitorSettingsView())
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Hermes Monitor Settings"
            window.styleMask = [.titled, .closable]
            window.setFrameAutosaveName("HermesMonitor.Settings")
            window.delegate = self
            settingsWindowController = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === settingsWindowController?.window else {
            return
        }
        closingWindow.contentViewController = nil
        settingsWindowController = nil
    }
}
#else
import Foundation

@main
enum HermesMonitorApp {
    static func main() {
        print("HermesMonitorApp requires macOS with SwiftUI and AppKit.")
    }
}
#endif