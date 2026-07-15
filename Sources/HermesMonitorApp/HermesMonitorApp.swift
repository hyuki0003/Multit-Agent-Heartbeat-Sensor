#if canImport(SwiftUI)
import AppKit
import SwiftUI

@main
struct HermesMonitorApp: App {
    @NSApplicationDelegateAdaptor(HermesMonitorAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("Toggle Hermes Monitor") {
                    NotificationCenter.default.post(name: .toggleHermesMonitorPanel, object: nil)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class HermesMonitorAppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: FloatingPanelController?
    private var viewModel: MonitorViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model: MonitorViewModel
        do {
            let client = try MonitorConnectionSettings.load().makeClient()
            model = MonitorViewModel(client: client)
        } catch {
            model = MonitorViewModel(client: nil, initialError: error.localizedDescription)
        }

        viewModel = model
        panelController = FloatingPanelController(rootView: MonitorRootView(viewModel: model))
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTogglePanel(_:)),
            name: .toggleHermesMonitorPanel,
            object: nil
        )
        panelController?.show()
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
