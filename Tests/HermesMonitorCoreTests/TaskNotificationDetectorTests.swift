import XCTest
@testable import HermesMonitorCore

final class TaskNotificationDetectorTests: XCTestCase {
    func testInitialSnapshotEstablishesBaselineWithoutNotifications() {
        var detector = TaskNotificationDetector()
        let now = Date(timeIntervalSince1970: 1_000)

        let events = detector.events(
            for: snapshot([correlatedTask(id: "running", status: .running, now: now)], at: now),
            at: now
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testRunningToBlockedProducesBlockedEvent() {
        var detector = TaskNotificationDetector()
        let now = Date(timeIntervalSince1970: 1_000)
        establishRunningBaseline(in: &detector, id: "blocked", now: now)

        let events = detector.events(
            for: snapshot([correlatedTask(id: "blocked", status: .blocked, now: now)], at: now),
            at: now
        )

        XCTAssertEqual(events, [
            TaskNotificationEvent(
                taskID: "blocked",
                taskTitle: "Blocked",
                kind: .blocked
            )
        ])
    }

    func testRunningToDoneProducesCompletedEvent() {
        var detector = TaskNotificationDetector()
        let now = Date(timeIntervalSince1970: 1_000)
        establishRunningBaseline(in: &detector, id: "done", now: now)

        let events = detector.events(
            for: snapshot([correlatedTask(id: "done", status: .done, now: now)], at: now),
            at: now
        )

        XCTAssertEqual(events.map(\.kind), [.completed])
    }

    func testFailedCurrentRunProducesFailedEvent() {
        var detector = TaskNotificationDetector()
        let now = Date(timeIntervalSince1970: 1_000)
        establishRunningBaseline(in: &detector, id: "failed", now: now)
        let failedRun = TaskRun(
            id: 7,
            taskID: "failed",
            profile: "rune",
            status: .crashed,
            startedAt: now.addingTimeInterval(-20),
            endedAt: now,
            outcome: .crashed
        )

        let events = detector.events(
            for: snapshot([
                correlatedTask(
                    id: "failed",
                    status: .running,
                    now: now,
                    currentRun: failedRun
                )
            ], at: now),
            at: now
        )

        XCTAssertEqual(events.map(\.kind), [.failed])
    }

    func testRunningHeartbeatCrossing180SecondsProducesOneStaleEvent() {
        var detector = TaskNotificationDetector()
        let baseline = Date(timeIntervalSince1970: 1_000)
        let heartbeat = baseline.addingTimeInterval(-170)
        _ = detector.events(
            for: snapshot([
                correlatedTask(
                    id: "stale",
                    status: .running,
                    now: baseline,
                    heartbeat: heartbeat
                )
            ], at: baseline),
            at: baseline
        )

        let staleTime = baseline.addingTimeInterval(11)
        let staleSnapshot = snapshot([
            correlatedTask(
                id: "stale",
                status: .running,
                now: staleTime,
                heartbeat: heartbeat
            )
        ], at: staleTime)

        XCTAssertEqual(detector.events(for: staleSnapshot, at: staleTime).map(\.kind), [.heartbeatStale])
        XCTAssertTrue(detector.events(for: staleSnapshot, at: staleTime.addingTimeInterval(10)).isEmpty)
    }

    func testNewTaskNotificationIsOptional() {
        var detector = TaskNotificationDetector()
        let now = Date(timeIntervalSince1970: 1_000)
        _ = detector.events(for: snapshot([], at: now), at: now)
        let newTask = snapshot([correlatedTask(id: "new", status: .ready, now: now)], at: now)

        XCTAssertTrue(detector.events(for: newTask, at: now).isEmpty)

        var enabledDetector = TaskNotificationDetector()
        _ = enabledDetector.events(for: snapshot([], at: now), at: now)
        let preferences = TaskNotificationPreferences(notifyOnNewTask: true)
        XCTAssertEqual(
            enabledDetector.events(for: newTask, at: now, preferences: preferences).map(\.kind),
            [.created]
        )
    }

    func testDuplicateTransitionIsSuppressedFor60Seconds() {
        var detector = TaskNotificationDetector(deduplicationWindow: 60)
        let start = Date(timeIntervalSince1970: 1_000)
        establishRunningBaseline(in: &detector, id: "flapping", now: start)

        let first = detector.events(
            for: snapshot([correlatedTask(id: "flapping", status: .blocked, now: start)], at: start),
            at: start
        )
        _ = detector.events(
            for: snapshot([correlatedTask(id: "flapping", status: .running, now: start)], at: start),
            at: start.addingTimeInterval(10)
        )
        let duplicate = detector.events(
            for: snapshot([correlatedTask(id: "flapping", status: .blocked, now: start)], at: start),
            at: start.addingTimeInterval(20)
        )
        _ = detector.events(
            for: snapshot([correlatedTask(id: "flapping", status: .running, now: start)], at: start),
            at: start.addingTimeInterval(65)
        )
        let afterWindow = detector.events(
            for: snapshot([correlatedTask(id: "flapping", status: .blocked, now: start)], at: start),
            at: start.addingTimeInterval(70)
        )

        XCTAssertEqual(first.map(\.kind), [.blocked])
        XCTAssertTrue(duplicate.isEmpty)
        XCTAssertEqual(afterWindow.map(\.kind), [.blocked])
    }

    private func establishRunningBaseline(
        in detector: inout TaskNotificationDetector,
        id: String,
        now: Date
    ) {
        _ = detector.events(
            for: snapshot([correlatedTask(id: id, status: .running, now: now)], at: now),
            at: now
        )
    }

    private func snapshot(_ tasks: [CorrelatedTask], at now: Date) -> HermesMonitorSnapshot {
        HermesMonitorSnapshot(
            kanban: KanbanSnapshot(
                tasks: tasks.map(\.task),
                runs: tasks.compactMap(\.currentRun),
                events: [],
                comments: [],
                links: []
            ),
            state: StateSnapshot(sessions: []),
            tasks: tasks,
            logTails: [:],
            warnings: [],
            refreshedAt: now
        )
    }

    private func correlatedTask(
        id: String,
        status: KanbanTaskStatus,
        now: Date,
        heartbeat: Date? = nil,
        currentRun: TaskRun? = nil
    ) -> CorrelatedTask {
        let task = KanbanTask(
            id: id,
            title: id.capitalized,
            status: status,
            createdAt: now.addingTimeInterval(-300),
            lastHeartbeatAt: heartbeat ?? (status == .running ? now : nil),
            currentRunID: currentRun?.id
        )
        return CorrelatedTask(
            task: task,
            currentRun: currentRun,
            runConfidence: currentRun == nil ? .notApplicable : .direct,
            session: nil,
            sessionConfidence: .notApplicable,
            parentSession: nil,
            evidence: [],
            workerLogRemotePath: "/home/dhlee/.hermes/kanban/logs/\(id).log"
        )
    }
}
