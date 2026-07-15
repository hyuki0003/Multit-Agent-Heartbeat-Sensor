import Foundation

public enum TaskNotificationKind: String, Codable, CaseIterable, Equatable, Sendable {
    case blocked
    case completed
    case failed
    case heartbeatStale = "heartbeat_stale"
    case created

    public var playsDeathSound: Bool {
        switch self {
        case .completed, .failed, .heartbeatStale:
            return true
        case .blocked, .created:
            return false
        }
    }
}

public struct TaskNotificationEvent: Equatable, Sendable {
    public let taskID: String
    public let taskTitle: String
    public let kind: TaskNotificationKind

    public init(taskID: String, taskTitle: String, kind: TaskNotificationKind) {
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.kind = kind
    }

    public var deduplicationKey: String {
        "\(taskID):\(kind.rawValue)"
    }
}

public struct TaskNotificationPreferences: Equatable, Sendable {
    public let notifyOnBlocked: Bool
    public let notifyOnCompleted: Bool
    public let notifyOnFailed: Bool
    public let notifyOnHeartbeatStale: Bool
    public let notifyOnNewTask: Bool

    public init(
        notifyOnBlocked: Bool = true,
        notifyOnCompleted: Bool = true,
        notifyOnFailed: Bool = true,
        notifyOnHeartbeatStale: Bool = true,
        notifyOnNewTask: Bool = false
    ) {
        self.notifyOnBlocked = notifyOnBlocked
        self.notifyOnCompleted = notifyOnCompleted
        self.notifyOnFailed = notifyOnFailed
        self.notifyOnHeartbeatStale = notifyOnHeartbeatStale
        self.notifyOnNewTask = notifyOnNewTask
    }

    public func isEnabled(_ kind: TaskNotificationKind) -> Bool {
        switch kind {
        case .blocked: return notifyOnBlocked
        case .completed: return notifyOnCompleted
        case .failed: return notifyOnFailed
        case .heartbeatStale: return notifyOnHeartbeatStale
        case .created: return notifyOnNewTask
        }
    }

    public func shouldPlayDeathSound(for kind: TaskNotificationKind) -> Bool {
        isEnabled(kind) && kind.playsDeathSound
    }
}

public struct TaskNotificationDetector: Sendable {
    private struct ObservedTaskState: Sendable {
        let visualStatus: TaskVisualStatus
        let heartbeatIsStale: Bool
    }

    private let deduplicationWindow: TimeInterval
    private var hasBaseline = false
    private var previousStates: [String: ObservedTaskState] = [:]
    private var lastDeliveredAt: [String: Date] = [:]

    public init(deduplicationWindow: TimeInterval = 60) {
        self.deduplicationWindow = max(0, deduplicationWindow)
    }

    public mutating func events(
        for snapshot: HermesMonitorSnapshot,
        at now: Date = Date(),
        preferences: TaskNotificationPreferences = TaskNotificationPreferences()
    ) -> [TaskNotificationEvent] {
        let currentStates = Dictionary(
            uniqueKeysWithValues: snapshot.tasks.map { task in
                (
                    task.id,
                    ObservedTaskState(
                        visualStatus: task.visualStatus,
                        heartbeatIsStale: task.task.isHeartbeatStale(at: now, threshold: 180)
                    )
                )
            }
        )

        guard hasBaseline else {
            previousStates = currentStates
            hasBaseline = true
            return []
        }

        var candidates: [TaskNotificationEvent] = []
        for task in snapshot.tasks {
            let current = currentStates[task.id]
            guard let current else { continue }

            guard let previous = previousStates[task.id] else {
                candidates.append(event(for: task, kind: .created))
                continue
            }

            if previous.visualStatus != current.visualStatus {
                switch current.visualStatus {
                case .blocked:
                    if previous.visualStatus == .running {
                        candidates.append(event(for: task, kind: .blocked))
                    }
                case .done:
                    candidates.append(event(for: task, kind: .completed))
                case .failed:
                    candidates.append(event(for: task, kind: .failed))
                case .todo, .ready, .running, .archived:
                    break
                }
            }

            if current.visualStatus == .running,
               !previous.heartbeatIsStale,
               current.heartbeatIsStale {
                candidates.append(event(for: task, kind: .heartbeatStale))
            }
        }

        previousStates = currentStates
        lastDeliveredAt = lastDeliveredAt.filter {
            now.timeIntervalSince($0.value) < deduplicationWindow
        }

        return candidates.filter { candidate in
            guard preferences.isEnabled(candidate.kind) else { return false }
            if let deliveredAt = lastDeliveredAt[candidate.deduplicationKey],
               now.timeIntervalSince(deliveredAt) < deduplicationWindow {
                return false
            }
            lastDeliveredAt[candidate.deduplicationKey] = now
            return true
        }
    }

    private func event(
        for task: CorrelatedTask,
        kind: TaskNotificationKind
    ) -> TaskNotificationEvent {
        TaskNotificationEvent(
            taskID: task.id,
            taskTitle: task.task.title,
            kind: kind
        )
    }
}
