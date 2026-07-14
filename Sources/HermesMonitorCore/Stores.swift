import Foundation

public struct KanbanStore: Sendable {
    private let database: ReadOnlySQLiteDatabase

    public init(database: ReadOnlySQLiteDatabase) {
        self.database = database
    }

    public func loadSnapshot() throws -> KanbanSnapshot {
        KanbanSnapshot(
            tasks: try loadTasks(),
            runs: try loadRuns(),
            events: try loadEvents(),
            comments: try loadComments(),
            links: try loadLinks()
        )
    }

    public func loadTasks() throws -> [KanbanTask] {
        try database.query(
            """
            SELECT id, title, body, assignee, status, priority, created_at, started_at,
                   completed_at, workspace_kind, workspace_path, worker_pid,
                   last_heartbeat_at, current_run_id, session_id, result,
                   consecutive_failures, last_failure_error
            FROM tasks
            ORDER BY priority DESC, created_at ASC
            """
        ) { row in
            let statusValue = try row.requiredString(4)
            guard let status = KanbanTaskStatus(rawValue: statusValue) else {
                throw SQLiteStoreError.invalidValue(column: 4, value: statusValue)
            }
            return KanbanTask(
                id: try row.requiredString(0),
                title: try row.requiredString(1),
                body: row.optionalString(2),
                assignee: row.optionalString(3),
                status: status,
                priority: Int(try row.requiredInt64(5)),
                createdAt: try row.requiredDate(6),
                startedAt: row.optionalDate(7),
                completedAt: row.optionalDate(8),
                workspaceKind: row.optionalString(9),
                workspacePath: row.optionalString(10),
                workerPID: row.optionalInt64(11),
                lastHeartbeatAt: row.optionalDate(12),
                currentRunID: row.optionalInt64(13),
                sessionID: row.optionalString(14),
                result: row.optionalString(15),
                consecutiveFailures: Int(row.optionalInt64(16) ?? 0),
                lastFailureError: row.optionalString(17)
            )
        }
    }

    public func loadRuns() throws -> [TaskRun] {
        try database.query(
            """
            SELECT id, task_id, profile, status, worker_pid, last_heartbeat_at,
                   started_at, ended_at, outcome, summary, metadata, error
            FROM task_runs
            ORDER BY started_at ASC, id ASC
            """
        ) { row in
            let statusValue = try row.requiredString(3)
            guard let status = TaskRunStatus(rawValue: statusValue) else {
                throw SQLiteStoreError.invalidValue(column: 3, value: statusValue)
            }
            let outcome: TaskRunOutcome?
            if let value = row.optionalString(8) {
                guard let parsed = TaskRunOutcome(rawValue: value) else {
                    throw SQLiteStoreError.invalidValue(column: 8, value: value)
                }
                outcome = parsed
            } else {
                outcome = nil
            }
            return TaskRun(
                id: try row.requiredInt64(0),
                taskID: try row.requiredString(1),
                profile: try row.requiredString(2),
                status: status,
                workerPID: row.optionalInt64(4),
                lastHeartbeatAt: row.optionalDate(5),
                startedAt: try row.requiredDate(6),
                endedAt: row.optionalDate(7),
                outcome: outcome,
                summary: row.optionalString(9),
                metadata: row.optionalString(10),
                error: row.optionalString(11)
            )
        }
    }

    public func loadEvents() throws -> [TaskEvent] {
        try database.query(
            """
            SELECT id, task_id, run_id, kind, payload, created_at
            FROM task_events
            ORDER BY created_at ASC, id ASC
            """
        ) { row in
            TaskEvent(
                id: try row.requiredInt64(0),
                taskID: try row.requiredString(1),
                runID: row.optionalInt64(2),
                kind: try row.requiredString(3),
                payload: row.optionalString(4),
                createdAt: try row.requiredDate(5)
            )
        }
    }

    public func loadComments() throws -> [TaskComment] {
        try database.query(
            """
            SELECT id, task_id, author, body, created_at
            FROM task_comments
            ORDER BY created_at ASC, id ASC
            """
        ) { row in
            TaskComment(
                id: try row.requiredInt64(0),
                taskID: try row.requiredString(1),
                author: try row.requiredString(2),
                body: try row.requiredString(3),
                createdAt: try row.requiredDate(4)
            )
        }
    }

    public func loadLinks() throws -> [TaskLink] {
        try database.query(
            "SELECT parent_id, child_id FROM task_links ORDER BY parent_id, child_id"
        ) { row in
            TaskLink(parentID: try row.requiredString(0), childID: try row.requiredString(1))
        }
    }
}

public struct StateStore: Sendable {
    private let database: ReadOnlySQLiteDatabase

    public init(database: ReadOnlySQLiteDatabase) {
        self.database = database
    }

    public func loadSnapshot() throws -> StateSnapshot {
        StateSnapshot(sessions: try loadSessions())
    }

    public func loadSessions() throws -> [HermesSession] {
        try database.query(
            """
            SELECT id, source, user_id, model, parent_session_id, started_at, ended_at,
                   end_reason, message_count, tool_call_count, cwd, title, handoff_state
            FROM sessions
            ORDER BY started_at ASC
            """
        ) { row in
            HermesSession(
                id: try row.requiredString(0),
                source: try row.requiredString(1),
                userID: row.optionalString(2),
                model: row.optionalString(3),
                parentSessionID: row.optionalString(4),
                startedAt: try row.requiredDate(5),
                endedAt: row.optionalDate(6),
                endReason: row.optionalString(7),
                messageCount: Int(row.optionalInt64(8) ?? 0),
                toolCallCount: Int(row.optionalInt64(9) ?? 0),
                cwd: row.optionalString(10),
                title: row.optionalString(11),
                handoffState: row.optionalString(12)
            )
        }
    }

    public func messages(sessionID: String, limit: Int = 200) throws -> [HermesMessage] {
        let safeLimit = max(1, min(limit, 10_000))
        let newestFirst = try database.query(
            """
            SELECT id, session_id, role, content, tool_calls, tool_name, timestamp, finish_reason
            FROM messages
            WHERE session_id = ?
            ORDER BY timestamp DESC, id DESC
            LIMIT ?
            """,
            bindings: [.text(sessionID), .int64(Int64(safeLimit))]
        ) { row in
            HermesMessage(
                id: try row.requiredInt64(0),
                sessionID: try row.requiredString(1),
                role: try row.requiredString(2),
                content: row.optionalString(3),
                toolCalls: row.optionalString(4),
                toolName: row.optionalString(5),
                timestamp: try row.requiredDate(6),
                finishReason: row.optionalString(7)
            )
        }
        return Array(newestFirst.reversed())
    }
}
