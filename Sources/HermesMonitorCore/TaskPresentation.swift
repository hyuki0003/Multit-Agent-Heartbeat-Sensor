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

public extension KanbanTask {
    func liveness(
        at now: Date = Date(),
        staleAfter: TimeInterval = 60,
        deadAfter: TimeInterval = 180
    ) -> TaskLivenessState {
        guard status == .running else { return .inactive }
        guard let lastHeartbeatAt else { return .dead }

        let age = max(0, now.timeIntervalSince(lastHeartbeatAt))
        if age >= deadAfter { return .dead }
        if age >= staleAfter { return .stale }
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
        case .running, .done, .blocked, .released:
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
