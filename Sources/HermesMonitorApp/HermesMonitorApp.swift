#if canImport(SwiftUI)
import SwiftUI

@main
struct HermesMonitorApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Image(systemName: "heart.text.square")
                    .font(.system(size: 42))
                Text("Hermes Monitor")
                    .font(.title2.bold())
                Text("Foundation layer ready")
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 360, minHeight: 220)
        }
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
