import Foundation

public enum MappingConfidence: String, Codable, Equatable, Sendable {
    case direct
    case manual
    case inferred
    case unmatched
    case notApplicable
}

public struct CorrelatedTask: Identifiable, Equatable, Sendable {
    public var id: String { task.id }
    public let task: KanbanTask
    public let currentRun: TaskRun?
    public let runConfidence: MappingConfidence
    public let session: HermesSession?
    public let sessionConfidence: MappingConfidence
    public let parentSession: HermesSession?
    public let evidence: [String]
    public let workerLogRemotePath: String

    public var isUncertain: Bool {
        [runConfidence, sessionConfidence].contains(.inferred) ||
            [runConfidence, sessionConfidence].contains(.manual) ||
            [runConfidence, sessionConfidence].contains(.unmatched)
    }

    public init(
        task: KanbanTask,
        currentRun: TaskRun?,
        runConfidence: MappingConfidence,
        session: HermesSession?,
        sessionConfidence: MappingConfidence,
        parentSession: HermesSession?,
        evidence: [String],
        workerLogRemotePath: String
    ) {
        self.task = task
        self.currentRun = currentRun
        self.runConfidence = runConfidence
        self.session = session
        self.sessionConfidence = sessionConfidence
        self.parentSession = parentSession
        self.evidence = evidence
        self.workerLogRemotePath = workerLogRemotePath
    }
}

public struct TaskCorrelator: Sendable {
    private let manualSessionLinks: [String: String]
    private let pathPolicy: RemotePathPolicy

    public init(
        manualSessionLinks: [String: String] = [:],
        pathPolicy: RemotePathPolicy = RemotePathPolicy()
    ) {
        self.manualSessionLinks = manualSessionLinks
        self.pathPolicy = pathPolicy
    }

    public func correlate(
        tasks: [KanbanTask],
        runs: [TaskRun],
        sessions: [HermesSession]
    ) -> [CorrelatedTask] {
        let runsByID = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let runsByTask = Dictionary(grouping: runs, by: \TaskRun.taskID)
        let sessionsByWorkspace = Dictionary(
            grouping: sessions.filter { $0.cwd != nil },
            by: { $0.cwd ?? "" }
        )

        return tasks.map { task in
            var evidence: [String] = []
            let runResolution = resolveRun(
                for: task,
                runsByID: runsByID,
                runsForTask: runsByTask[task.id] ?? []
            )
            if let runEvidence = runResolution.evidence {
                evidence.append(runEvidence)
            }

            let sessionResolution = resolveSession(
                for: task,
                sessionsByID: sessionsByID,
                sessionsByWorkspace: sessionsByWorkspace
            )
            if let sessionEvidence = sessionResolution.evidence {
                evidence.append(sessionEvidence)
            }

            let parentSession = sessionResolution.value?.parentSessionID
                .flatMap { sessionsByID[$0] }
            if parentSession != nil {
                evidence.append("sessions.parent_session_id")
            }

            let logPath = (try? pathPolicy.workerLogPath(taskID: task.id)) ??
                "\(RemotePathPolicy.workerLogsDirectory)/invalid-task-id.log"

            return CorrelatedTask(
                task: task,
                currentRun: runResolution.value,
                runConfidence: runResolution.confidence,
                session: sessionResolution.value,
                sessionConfidence: sessionResolution.confidence,
                parentSession: parentSession,
                evidence: evidence,
                workerLogRemotePath: logPath
            )
        }
    }

    private func resolveRun(
        for task: KanbanTask,
        runsByID: [Int64: TaskRun],
        runsForTask: [TaskRun]
    ) -> Resolution<TaskRun> {
        if let currentRunID = task.currentRunID,
           let run = runsByID[currentRunID],
           run.taskID == task.id {
            return Resolution(value: run, confidence: .direct, evidence: "tasks.current_run_id")
        }

        if let workerPID = task.workerPID,
           let run = runsForTask
            .filter({ $0.workerPID == workerPID || $0.metadataPID == workerPID })
            .max(by: { $0.startedAt < $1.startedAt }) {
            return Resolution(value: run, confidence: .inferred, evidence: "worker_pid/metadata.pid")
        }

        if let latest = runsForTask.max(by: { $0.startedAt < $1.startedAt }) {
            return Resolution(value: latest, confidence: .inferred, evidence: "latest task_runs.task_id")
        }

        let isPending = task.status == .todo || task.status == .ready
        let confidence: MappingConfidence = isPending ? .notApplicable : .unmatched
        return Resolution(value: nil, confidence: confidence, evidence: nil)
    }

    private func resolveSession(
        for task: KanbanTask,
        sessionsByID: [String: HermesSession],
        sessionsByWorkspace: [String: [HermesSession]]
    ) -> Resolution<HermesSession> {
        if let sessionID = task.sessionID,
           let session = sessionsByID[sessionID] {
            return Resolution(value: session, confidence: .direct, evidence: "tasks.session_id")
        }

        if let manualSessionID = manualSessionLinks[task.id],
           let session = sessionsByID[manualSessionID] {
            return Resolution(value: session, confidence: .manual, evidence: "manual task/session link")
        }

        if let workspacePath = task.workspacePath,
           let candidates = sessionsByWorkspace[workspacePath],
           candidates.count == 1,
           let session = candidates.first {
            return Resolution(value: session, confidence: .inferred, evidence: "tasks.workspace_path/sessions.cwd")
        }

        let isPending = task.status == .todo || task.status == .ready
        let confidence: MappingConfidence = isPending ? .notApplicable : .unmatched
        return Resolution(value: nil, confidence: confidence, evidence: nil)
    }
}

private struct Resolution<Value> {
    let value: Value?
    let confidence: MappingConfidence
    let evidence: String?
}
