import Foundation

public enum KanbanTaskStatus: String, Codable, CaseIterable, Sendable {
    case todo
    case ready
    case running
    case blocked
    case done
    case archived
}

public enum TaskRunStatus: String, Codable, CaseIterable, Sendable {
    case running
    case done
    case completed
    case blocked
    case crashed
    case timedOut = "timed_out"
    case failed
    case released
    case unknown
}

public enum TaskRunOutcome: String, Codable, CaseIterable, Sendable {
    case completed
    case blocked
    case crashed
    case timedOut = "timed_out"
    case spawnFailed = "spawn_failed"
    case gaveUp = "gave_up"
    case reclaimed
}

public enum TaskInstructionBinding: Equatable, Sendable {
    case unbound
    case run(Int64)
    case unavailable
}

public struct KanbanTask: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String?
    public let assignee: String?
    public let status: KanbanTaskStatus
    public let priority: Int
    public let createdAt: Date
    public let startedAt: Date?
    public let completedAt: Date?
    public let workspaceKind: String?
    public let workspacePath: String?
    public let workerPID: Int64?
    public let lastHeartbeatAt: Date?
    public let currentRunID: Int64?
    public let sessionID: String?
    public let result: String?
    public let consecutiveFailures: Int
    public let lastFailureError: String?

    public init(
        id: String,
        title: String,
        body: String? = nil,
        assignee: String? = nil,
        status: KanbanTaskStatus,
        priority: Int = 0,
        createdAt: Date,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        workspaceKind: String? = nil,
        workspacePath: String? = nil,
        workerPID: Int64? = nil,
        lastHeartbeatAt: Date? = nil,
        currentRunID: Int64? = nil,
        sessionID: String? = nil,
        result: String? = nil,
        consecutiveFailures: Int = 0,
        lastFailureError: String? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.assignee = assignee
        self.status = status
        self.priority = priority
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.workspaceKind = workspaceKind
        self.workspacePath = workspacePath
        self.workerPID = workerPID
        self.lastHeartbeatAt = lastHeartbeatAt
        self.currentRunID = currentRunID
        self.sessionID = sessionID
        self.result = result
        self.consecutiveFailures = consecutiveFailures
        self.lastFailureError = lastFailureError
    }

    public func isHeartbeatStale(at now: Date = Date(), threshold: TimeInterval = 180) -> Bool {
        guard status == .running else { return false }
        guard let lastHeartbeatAt else { return true }
        return now.timeIntervalSince(lastHeartbeatAt) >= threshold
    }
}

public struct TaskRun: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let taskID: String
    public let profile: String
    public let status: TaskRunStatus
    public let workerPID: Int64?
    public let lastHeartbeatAt: Date?
    public let startedAt: Date
    public let endedAt: Date?
    public let outcome: TaskRunOutcome?
    public let summary: String?
    public let metadata: String?
    public let error: String?

    public init(
        id: Int64,
        taskID: String,
        profile: String,
        status: TaskRunStatus,
        workerPID: Int64? = nil,
        lastHeartbeatAt: Date? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        outcome: TaskRunOutcome? = nil,
        summary: String? = nil,
        metadata: String? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.profile = profile
        self.status = status
        self.workerPID = workerPID
        self.lastHeartbeatAt = lastHeartbeatAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.summary = summary
        self.metadata = metadata
        self.error = error
    }

    public var metadataPID: Int64? {
        guard let metadata,
              let data = metadata.data(using: .utf8),
              let rawObject = try? JSONSerialization.jsonObject(with: data),
              let object = rawObject as? [String: Any],
              let pid = object["pid"] else {
            return nil
        }
        if let number = pid as? NSNumber { return number.int64Value }
        if let string = pid as? String { return Int64(string) }
        return nil
    }
}

public struct TaskEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let taskID: String
    public let runID: Int64?
    public let kind: String
    public let payload: String?
    public let createdAt: Date

    public init(id: Int64, taskID: String, runID: Int64?, kind: String, payload: String?, createdAt: Date) {
        self.id = id
        self.taskID = taskID
        self.runID = runID
        self.kind = kind
        self.payload = payload
        self.createdAt = createdAt
    }
}

public struct TaskComment: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let taskID: String
    public let author: String
    public let body: String
    public let createdAt: Date

    public init(id: Int64, taskID: String, author: String, body: String, createdAt: Date) {
        self.id = id
        self.taskID = taskID
        self.author = author
        self.body = body
        self.createdAt = createdAt
    }
}

public struct TaskLink: Codable, Hashable, Sendable {
    public let parentID: String
    public let childID: String

    public init(parentID: String, childID: String) {
        self.parentID = parentID
        self.childID = childID
    }
}

public struct HermesSession: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let source: String
    public let userID: String?
    public let model: String?
    public let parentSessionID: String?
    public let startedAt: Date
    public let endedAt: Date?
    public let endReason: String?
    public let messageCount: Int
    public let toolCallCount: Int
    public let cwd: String?
    public let title: String?
    public let handoffState: String?

    public init(
        id: String,
        source: String,
        userID: String? = nil,
        model: String? = nil,
        parentSessionID: String? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        endReason: String? = nil,
        messageCount: Int = 0,
        toolCallCount: Int = 0,
        cwd: String? = nil,
        title: String? = nil,
        handoffState: String? = nil
    ) {
        self.id = id
        self.source = source
        self.userID = userID
        self.model = model
        self.parentSessionID = parentSessionID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endReason = endReason
        self.messageCount = messageCount
        self.toolCallCount = toolCallCount
        self.cwd = cwd
        self.title = title
        self.handoffState = handoffState
    }
}

public struct HermesMessage: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let sessionID: String
    public let role: String
    public let content: String?
    public let toolCalls: String?
    public let toolName: String?
    public let timestamp: Date
    public let finishReason: String?

    public init(
        id: Int64,
        sessionID: String,
        role: String,
        content: String?,
        toolCalls: String?,
        toolName: String?,
        timestamp: Date,
        finishReason: String?
    ) {
        self.id = id
        self.sessionID = sessionID
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolName = toolName
        self.timestamp = timestamp
        self.finishReason = finishReason
    }
}

public struct KanbanSnapshot: Equatable, Sendable {
    public let tasks: [KanbanTask]
    public let runs: [TaskRun]
    public let events: [TaskEvent]
    public let comments: [TaskComment]
    public let links: [TaskLink]

    public init(
        tasks: [KanbanTask],
        runs: [TaskRun],
        events: [TaskEvent],
        comments: [TaskComment],
        links: [TaskLink]
    ) {
        self.tasks = tasks
        self.runs = runs
        self.events = events
        self.comments = comments
        self.links = links
    }
}

public struct StateSnapshot: Equatable, Sendable {
    public let sessions: [HermesSession]

    public init(sessions: [HermesSession]) {
        self.sessions = sessions
    }
}
