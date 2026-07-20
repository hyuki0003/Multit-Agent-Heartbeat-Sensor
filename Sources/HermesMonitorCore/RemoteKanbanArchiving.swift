import Foundation

public enum HermesKanbanArchiveError: Error, Equatable, LocalizedError {
    case invalidTaskID(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTaskID(let taskID):
            return "Refusing to archive noncanonical Hermes task ID: \(taskID)"
        }
    }
}

public enum HermesKanbanArchiveCommand {
    private static let canonicalTaskIDPattern = "^t_[0-9a-f]{8}$"
    private static let fixedPrefix =
        "/usr/bin/env HERMES_KANBAN_BOARD=default " +
        "HERMES_KANBAN_DB=/home/dhlee/.hermes/kanban.db " +
        "/home/dhlee/.hermes/hermes-agent/venv/bin/hermes kanban archive "

    public static func remoteCommand(taskID: String) throws -> String {
        guard taskID.range(
            of: canonicalTaskIDPattern,
            options: .regularExpression
        ) == taskID.startIndex..<taskID.endIndex else {
            throw HermesKanbanArchiveError.invalidTaskID(taskID)
        }
        return fixedPrefix + taskID
    }
}

public protocol RemoteKanbanArchiving: Sendable {
    func archiveDoneTask(taskID: String) async throws
}

public protocol HermesMonitorServing: Sendable {
    func authoritativeTaskStatus(taskID: String) async throws -> KanbanTaskStatus?
    func refresh() async throws -> HermesMonitorSnapshot
    func archiveDoneTask(taskID: String) async throws
}

public enum RemoteArchiveWorkflowError: Error, Equatable, LocalizedError {
    case alreadyInProgress(taskID: String)
    case taskNoLongerDone(taskID: String, status: KanbanTaskStatus?)
    case refreshFailedAfterArchive(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyInProgress(let taskID):
            return "An archive request is already in progress for \(taskID)."
        case .taskNoLongerDone:
            return "Task is no longer Done; it was not removed. Refresh to review its current status."
        case .refreshFailedAfterArchive(let message):
            return "The remote archive succeeded, but the refreshed board could not be loaded: \(message)"
        }
    }
}

public actor RemoteArchiveWorkflow {
    private let service: any HermesMonitorServing
    private var inFlightTaskIDs: Set<String> = []

    public init(service: any HermesMonitorServing) {
        self.service = service
    }

    public func archiveAndRefresh(taskID: String) async throws -> HermesMonitorSnapshot {
        guard inFlightTaskIDs.insert(taskID).inserted else {
            throw RemoteArchiveWorkflowError.alreadyInProgress(taskID: taskID)
        }
        defer { inFlightTaskIDs.remove(taskID) }

        // This narrows the stale-snapshot window but cannot eliminate the residual TOCTOU
        // race across two remote operations; the server-side archive command remains the
        // final authority and must still reject tasks that are no longer Done.
        let authoritativeStatus = try await service.authoritativeTaskStatus(taskID: taskID)
        guard authoritativeStatus == .done else {
            throw RemoteArchiveWorkflowError.taskNoLongerDone(
                taskID: taskID,
                status: authoritativeStatus
            )
        }

        try await service.archiveDoneTask(taskID: taskID)
        do {
            return try await service.refresh()
        } catch {
            throw RemoteArchiveWorkflowError.refreshFailedAfterArchive(error.localizedDescription)
        }
    }
}
