import XCTest
@testable import HermesMonitorCore

final class TaskCorrelatorTests: XCTestCase {
    func testUsesDirectRunSessionAndParentSessionPointers() {
        let task = KanbanTask(
            id: "t_1",
            title: "Task",
            status: .running,
            createdAt: Date(timeIntervalSince1970: 100),
            currentRunID: 7,
            sessionID: "worker-session"
        )
        let run = TaskRun(
            id: 7,
            taskID: "t_1",
            profile: "rune-implementer",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 110)
        )
        let parent = HermesSession(
            id: "parent-session",
            source: "cli",
            startedAt: Date(timeIntervalSince1970: 90)
        )
        let worker = HermesSession(
            id: "worker-session",
            source: "kanban",
            parentSessionID: "parent-session",
            startedAt: Date(timeIntervalSince1970: 110)
        )

        let result = TaskCorrelator().correlate(
            tasks: [task],
            runs: [run],
            sessions: [parent, worker]
        )

        XCTAssertEqual(result[0].currentRun?.id, 7)
        XCTAssertEqual(result[0].runConfidence, .direct)
        XCTAssertEqual(result[0].session?.id, "worker-session")
        XCTAssertEqual(result[0].sessionConfidence, .direct)
        XCTAssertEqual(result[0].parentSession?.id, "parent-session")
        XCTAssertFalse(result[0].isUncertain)
    }

    func testMarksPIDAndWorkspaceFallbackAsUncertain() {
        let task = KanbanTask(
            id: "t_2",
            title: "Fallback",
            status: .running,
            createdAt: Date(timeIntervalSince1970: 100),
            workspacePath: "/tmp/work",
            workerPID: 42
        )
        let run = TaskRun(
            id: 8,
            taskID: "t_2",
            profile: "rune",
            status: .running,
            workerPID: 42,
            startedAt: Date(timeIntervalSince1970: 120)
        )
        let session = HermesSession(
            id: "cwd-match",
            source: "kanban",
            startedAt: Date(timeIntervalSince1970: 120),
            cwd: "/tmp/work"
        )

        let result = TaskCorrelator().correlate(tasks: [task], runs: [run], sessions: [session])

        XCTAssertEqual(result[0].currentRun?.id, 8)
        XCTAssertEqual(result[0].runConfidence, .inferred)
        XCTAssertEqual(result[0].session?.id, "cwd-match")
        XCTAssertEqual(result[0].sessionConfidence, .inferred)
        XCTAssertTrue(result[0].isUncertain)
    }

    func testManualSessionLinkOverridesInferredWorkspaceMatch() {
        let task = KanbanTask(
            id: "t_3",
            title: "Manual",
            status: .running,
            createdAt: Date(timeIntervalSince1970: 100),
            workspacePath: "/tmp/work"
        )
        let inferred = HermesSession(
            id: "inferred",
            source: "kanban",
            startedAt: Date(timeIntervalSince1970: 120),
            cwd: "/tmp/work"
        )
        let selected = HermesSession(
            id: "selected",
            source: "kanban",
            startedAt: Date(timeIntervalSince1970: 121),
            cwd: "/tmp/other"
        )

        let result = TaskCorrelator(manualSessionLinks: ["t_3": "selected"]).correlate(
            tasks: [task],
            runs: [],
            sessions: [inferred, selected]
        )

        XCTAssertEqual(result[0].session?.id, "selected")
        XCTAssertEqual(result[0].sessionConfidence, .manual)
        XCTAssertTrue(result[0].isUncertain)
    }
}
