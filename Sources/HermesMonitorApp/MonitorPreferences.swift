import Foundation
import HermesMonitorCore

enum MonitorPreferenceKeys {
    static let refreshInterval = "HermesMonitor.refreshInterval"
    static let notifyOnBlocked = "HermesMonitor.notifications.blocked"
    static let notifyOnCompleted = "HermesMonitor.notifications.completed"
    static let notifyOnFailed = "HermesMonitor.notifications.failed"
    static let notifyOnHeartbeatStale = "HermesMonitor.notifications.heartbeatStale"
    static let notifyOnNewTask = "HermesMonitor.notifications.newTask"
    static let hotKey = "HermesMonitor.hotKey"
    static let hotKeyUsesCommand = "HermesMonitor.hotKey.command"
    static let hotKeyUsesShift = "HermesMonitor.hotKey.shift"
    static let hotKeyUsesOption = "HermesMonitor.hotKey.option"
    static let hotKeyUsesControl = "HermesMonitor.hotKey.control"
}

struct MonitorHotKeyPreference {
    static let supportedKeys = ["H", "J", "K", "L", "M"]

    let key: String
    let usesCommand: Bool
    let usesShift: Bool
    let usesOption: Bool
    let usesControl: Bool

    var displayName: String {
        (usesControl ? "⌃" : "") +
            (usesOption ? "⌥" : "") +
            (usesShift ? "⇧" : "") +
            (usesCommand ? "⌘" : "") +
            key
    }
}

enum MonitorPreferences {
    static func refreshInterval(defaults: UserDefaults = .standard) -> TimeInterval {
        let configured = (defaults.object(forKey: MonitorPreferenceKeys.refreshInterval) as? NSNumber)?
            .doubleValue ?? 10
        return min(max(configured, 2), 300)
    }

    static func notifications(
        defaults: UserDefaults = .standard
    ) -> TaskNotificationPreferences {
        TaskNotificationPreferences(
            notifyOnBlocked: bool(
                forKey: MonitorPreferenceKeys.notifyOnBlocked,
                defaultValue: true,
                defaults: defaults
            ),
            notifyOnCompleted: bool(
                forKey: MonitorPreferenceKeys.notifyOnCompleted,
                defaultValue: true,
                defaults: defaults
            ),
            notifyOnFailed: bool(
                forKey: MonitorPreferenceKeys.notifyOnFailed,
                defaultValue: true,
                defaults: defaults
            ),
            notifyOnHeartbeatStale: bool(
                forKey: MonitorPreferenceKeys.notifyOnHeartbeatStale,
                defaultValue: true,
                defaults: defaults
            ),
            notifyOnNewTask: bool(
                forKey: MonitorPreferenceKeys.notifyOnNewTask,
                defaultValue: false,
                defaults: defaults
            )
        )
    }

    static func hotKey(defaults: UserDefaults = .standard) -> MonitorHotKeyPreference {
        let configuredKey = defaults.string(forKey: MonitorPreferenceKeys.hotKey)?.uppercased()
        let key = configuredKey.flatMap {
            MonitorHotKeyPreference.supportedKeys.contains($0) ? $0 : nil
        } ?? "H"
        var usesCommand = bool(
            forKey: MonitorPreferenceKeys.hotKeyUsesCommand,
            defaultValue: true,
            defaults: defaults
        )
        var usesShift = bool(
            forKey: MonitorPreferenceKeys.hotKeyUsesShift,
            defaultValue: true,
            defaults: defaults
        )
        let usesOption = bool(
            forKey: MonitorPreferenceKeys.hotKeyUsesOption,
            defaultValue: false,
            defaults: defaults
        )
        let usesControl = bool(
            forKey: MonitorPreferenceKeys.hotKeyUsesControl,
            defaultValue: false,
            defaults: defaults
        )
        if !usesCommand && !usesShift && !usesOption && !usesControl {
            usesCommand = true
            usesShift = true
        }
        return MonitorHotKeyPreference(
            key: key,
            usesCommand: usesCommand,
            usesShift: usesShift,
            usesOption: usesOption,
            usesControl: usesControl
        )
    }

    private static func bool(
        forKey key: String,
        defaultValue: Bool,
        defaults: UserDefaults
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}
