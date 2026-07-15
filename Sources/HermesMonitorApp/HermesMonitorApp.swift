#if canImport(SwiftUI)
import AppKit
import SwiftUI

@main
struct HermesMonitorApp: App {
    @NSApplicationDelegateAdaptor(HermesMonitorAppDelegate.self) private var appDelegate

    var body: some Scene {
        // Invisible WindowGroup to satisfy SwiftUI App lifecycle requirements.
        // The real UI is the FloatingMonitorPanel managed by FloatingPanelController.
        WindowGroup("HermesMonitor") {
            EmptyView()
                .frame(width: 0, height: 0)
                .windowResizability(.contentSize)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 0, height: 0)

        Settings {
            MonitorSettingsView()
        }
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("Toggle Hermes Monitor") {
                    NotificationCenter.default.post(name: .toggleHermesMonitorPanel, object: nil)
                }
            }
        }
    }
}

@MainActor
final class HermesMonitorAppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: FloatingPanelController?
    private var viewModel: MonitorViewModel?
    private var hotKeyController: GlobalHotKeyController?
    private var menuBarController: MenuBarController?
    private var notificationController: TaskNotificationController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Close the invisible WindowGroup window that SwiftUI creates on launch.
        // The real UI is the FloatingMonitorPanel managed by FloatingPanelController.
        for window in NSApp.windows where !(window is NSPanel) {
            window.orderOut(nil)
        }

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
        notificationController = TaskNotificationController { [weak self] taskID in
            self?.viewModel?.selectTask(taskID)
            self?.panelController?.show()
        }
        notificationController?.requestAuthorization()
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
        panelController?.show()
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
}
#else
import Foundation

@main
enum HermesMonitorApp {
    static func main() {
        print("HermesMonitorApp requires macOS with SwiftUI.")
    }
}
#endif