import Foundation

public enum TaskListMode: String, CaseIterable, Equatable, Sendable {
    case expanded
    case compact
}

public enum TaskListModePreference {
    public static let taskListMode = "HermesMonitor.taskListMode"

    public static func load(defaults: UserDefaults = .standard) -> TaskListMode {
        guard let rawValue = defaults.string(forKey: taskListMode),
              let mode = TaskListMode(rawValue: rawValue) else {
            return .expanded
        }
        return mode
    }

    public static func save(_ mode: TaskListMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: taskListMode)
    }
}

public enum CollapsedTaskGroupPreference {
    public static let collapsedGroupIDs = "HermesMonitor.collapsedGroupIDs"

    public static func load(defaults: UserDefaults = .standard) -> Set<String> {
        decode(defaults.string(forKey: collapsedGroupIDs) ?? "")
    }

    public static func save(_ taskIDs: Set<String>, defaults: UserDefaults = .standard) {
        defaults.set(encode(taskIDs), forKey: collapsedGroupIDs)
    }

    public static func encode(_ taskIDs: Set<String>) -> String {
        taskIDs.sorted().joined(separator: ",")
    }

    public static func decode(_ value: String) -> Set<String> {
        Set(value.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }
}

public enum AutomaticDoneArchivePreference {
    public static let automaticallyRemoveDoneTasks = "HermesMonitor.automaticallyRemoveDoneTasks"

    public static func load(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: automaticallyRemoveDoneTasks) != nil else {
            return false
        }
        return defaults.bool(forKey: automaticallyRemoveDoneTasks)
    }

    public static func save(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: automaticallyRemoveDoneTasks)
    }
}

public enum CompactTaskLayout {
    public static let minimumPanelWidth = 360
    public static let horizontalInset = 12
    public static let disclosureHitTarget = 44
    public static let percentageReservation = 40
    public static let availableContentWidth =
        minimumPanelWidth - 2 * horizontalInset - disclosureHitTarget - percentageReservation
}
