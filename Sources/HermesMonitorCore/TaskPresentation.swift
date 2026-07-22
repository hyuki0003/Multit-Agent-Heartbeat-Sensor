import Foundation

public enum TaskLivenessState: String, Codable, CaseIterable, Equatable, Sendable {
    case inactive
    case fresh
    case stale
    case dead
}

public enum TaskVisualStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case todo
    case ready
    case running
    case blocked
    case done
    case archived
    case failed
}

public enum TaskLivenessThresholds {
    public static let staleAfter: TimeInterval = 120
    public static let deadAfter: TimeInterval = 180
}

public enum HeartbeatTone: String, Codable, Equatable, Sendable {
    case inactive
    case healthy
    case stale
    case dead
    case blocked
    case completed
}

public enum HeartbeatMotion: String, Codable, Equatable, Sendable {
    case none
    case beatOnHeartbeatUpdate
}

public enum ECGWaveformMotion: String, Codable, Equatable, Sendable {
    case flatline
    case continuous
    case occasionalBlip
}

public struct TaskHeartbeatPresentation: Equatable, Sendable {
    public let heartTone: HeartbeatTone
    public let heartMotion: HeartbeatMotion
    public let waveformMotion: ECGWaveformMotion

    public init(status: TaskVisualStatus, liveness: TaskLivenessState) {
        switch status {
        case .running:
            switch liveness {
            case .fresh:
                heartTone = .healthy
                heartMotion = .beatOnHeartbeatUpdate
                waveformMotion = .continuous
            case .stale:
                heartTone = .stale
                heartMotion = .beatOnHeartbeatUpdate
                waveformMotion = .continuous
            case .dead:
                heartTone = .dead
                heartMotion = .none
                waveformMotion = .flatline
            case .inactive:
                heartTone = .inactive
                heartMotion = .none
                waveformMotion = .flatline
            }
        case .blocked:
            heartTone = .blocked
            heartMotion = .none
            waveformMotion = .occasionalBlip
        case .done, .archived:
            heartTone = .completed
            heartMotion = .none
            waveformMotion = .flatline
        case .failed:
            heartTone = .dead
            heartMotion = .none
            waveformMotion = .flatline
        case .todo, .ready:
            heartTone = .inactive
            heartMotion = .none
            waveformMotion = .flatline
        }
    }
}

public extension KanbanTask {
    func liveness(
        at now: Date = Date(),
        staleAfter: TimeInterval = TaskLivenessThresholds.staleAfter,
        deadAfter: TimeInterval = TaskLivenessThresholds.deadAfter
    ) -> TaskLivenessState {
        guard status == .running else { return .inactive }
        guard let lastHeartbeatAt else { return .dead }

        let age = max(0, now.timeIntervalSince(lastHeartbeatAt))
        if age >= deadAfter { return .dead }
        if age > staleAfter { return .stale }
        return .fresh
    }
}

public extension CorrelatedTask {
    var visualStatus: TaskVisualStatus {
        if currentRun?.isFailedForDisplay == true {
            return .failed
        }

        switch task.status {
        case .todo: return .todo
        case .ready: return .ready
        case .running: return .running
        case .blocked: return .blocked
        case .done: return .done
        case .archived: return .archived
        }
    }
}

private extension TaskRun {
    var isFailedForDisplay: Bool {
        switch status {
        case .crashed, .timedOut, .failed:
            return true
        case .running, .done, .completed, .blocked, .released, .unknown:
            break
        }

        guard let outcome else { return false }
        switch outcome {
        case .crashed, .timedOut, .spawnFailed, .gaveUp:
            return true
        case .completed, .blocked, .reclaimed:
            return false
        }
    }
}

public struct TaskPresentationGroup: Identifiable, Equatable, Sendable {
    public var id: String { parent.id }
    public let parent: CorrelatedTask
    public let children: [CorrelatedTask]

    public var isStandalone: Bool { children.isEmpty }
    public var childCount: Int { children.count }
    public var compactDrillDownTasks: [CorrelatedTask] { children }
    public var completedChildCount: Int {
        children.filter {
            $0.task.status == .done || $0.task.status == .archived
        }.count
    }
    public var childProgressPercent: Int {
        guard childCount > 0 else { return 0 }
        return completedChildCount * 100 / childCount
    }

    public var totalCount: Int { children.count + 1 }
    public var completedCount: Int {
        ([parent] + children).filter {
            $0.task.status == .done || $0.task.status == .archived
        }.count
    }

    public init(parent: CorrelatedTask, children: [CorrelatedTask]) {
        self.parent = parent
        self.children = children
    }

    public func liveness(at now: Date = Date()) -> TaskGroupLivenessState {
        let activeStates = ([parent] + children)
            .filter { $0.task.status == .running }
            .map { item -> TaskGroupLivenessState in
                switch item.task.liveness(at: now) {
                case .fresh: return .fresh
                case .stale: return .stale
                case .dead: return .dead
                case .inactive: return .unknown
                }
            }
        guard !activeStates.isEmpty else { return .unknown }
        return activeStates.max(by: { $0.severity < $1.severity }) ?? .unknown
    }
}

public enum TaskGroupLivenessState: String, Equatable, Sendable {
    case unknown
    case fresh
    case stale
    case dead

    fileprivate var severity: Int {
        switch self {
        case .unknown: return 0
        case .fresh: return 1
        case .stale: return 2
        case .dead: return 3
        }
    }
}

public enum ActiveBoardProjection {
    /// Returns the active-board task rows, excluding only `.archived`.
    ///
    /// Archived rows remain present in `KanbanStore.loadTasks()` and in every
    /// snapshot so `HermesMonitorClient.authoritativeTaskStatus` can verify
    /// write-through. This projection is applied only at the `TaskListView`
    /// presentation boundary, immediately before `TaskGroupBuilder.groups`,
    /// so server-archived tasks disappear from the active monitoring board
    /// while `.done` and every other status stay visible (failures stay
    /// inspectable/retryable).
    public static func activeBoardTasks(from tasks: [CorrelatedTask]) -> [CorrelatedTask] {
        tasks.filter { $0.task.status != .archived }
    }
}

public enum TaskGroupBuilder {
    public static func groups(
        tasks: [CorrelatedTask],
        links: [TaskLink]
    ) -> [TaskPresentationGroup] {
        var taskByID: [String: CorrelatedTask] = [:]
        for task in tasks where taskByID[task.id] == nil {
            taskByID[task.id] = task
        }

        var orderByID: [String: Int] = [:]
        for (offset, task) in tasks.enumerated() where orderByID[task.id] == nil {
            orderByID[task.id] = offset
        }
        var childrenByParent: [String: [String]] = [:]
        var linkedChildIDs: Set<String> = []

        for link in links {
            guard link.parentID != link.childID,
                  taskByID[link.parentID] != nil,
                  taskByID[link.childID] != nil else {
                continue
            }
            if childrenByParent[link.parentID, default: []].contains(link.childID) == false {
                childrenByParent[link.parentID, default: []].append(link.childID)
            }
            linkedChildIDs.insert(link.childID)
        }
        for parentID in Array(childrenByParent.keys) {
            childrenByParent[parentID]?.sort {
                orderByID[$0, default: .max] < orderByID[$1, default: .max]
            }
        }

        var visited: Set<String> = []

        func collectDescendants(of parentID: String) -> [CorrelatedTask] {
            var descendants: [CorrelatedTask] = []
            for childID in childrenByParent[parentID, default: []] where !visited.contains(childID) {
                guard let child = taskByID[childID] else { continue }
                visited.insert(childID)
                descendants.append(child)
                descendants.append(contentsOf: collectDescendants(of: childID))
            }
            return descendants
        }

        func makeGroup(root: CorrelatedTask) -> TaskPresentationGroup? {
            guard !visited.contains(root.id) else { return nil }
            visited.insert(root.id)
            return TaskPresentationGroup(
                parent: root,
                children: collectDescendants(of: root.id)
            )
        }

        let roots = tasks.filter { !linkedChildIDs.contains($0.id) }
        var result = roots.compactMap(makeGroup)

        // Malformed cyclic link graphs have no root. Keep every task visible by
        // promoting the first still-unvisited task to a group root.
        result.append(contentsOf: tasks.compactMap(makeGroup))
        return result
    }
}
