import XCTest
@testable import HermesMonitorCore

final class TaskPresentationTests: XCTestCase {
    func testRunningLivenessUsesFreshStaleAndDeadThresholds() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(makeTask(id: "fresh", heartbeatAge: 120, now: now).liveness(at: now), .fresh)
        XCTAssertEqual(makeTask(id: "stale", heartbeatAge: 120.001, now: now).liveness(at: now), .stale)
        XCTAssertEqual(makeTask(id: "edge", heartbeatAge: 179, now: now).liveness(at: now), .stale)
        XCTAssertEqual(makeTask(id: "dead", heartbeatAge: 180, now: now).liveness(at: now), .dead)
        XCTAssertEqual(makeTask(id: "missing", heartbeatAge: nil, now: now).liveness(at: now), .dead)
    }

    func testHeartbeatPresentationMatchesStatusAnimationContract() {
        let fresh = TaskHeartbeatPresentation(status: .running, liveness: .fresh)
        XCTAssertEqual(fresh.heartTone, .healthy)
        XCTAssertEqual(fresh.heartMotion, .beatOnHeartbeatUpdate)
        XCTAssertEqual(fresh.waveformMotion, .continuous)

        let stale = TaskHeartbeatPresentation(status: .running, liveness: .stale)
        XCTAssertEqual(stale.heartTone, .stale)
        XCTAssertEqual(stale.heartMotion, .beatOnHeartbeatUpdate)
        XCTAssertEqual(stale.waveformMotion, .continuous)

        let dead = TaskHeartbeatPresentation(status: .running, liveness: .dead)
        XCTAssertEqual(dead.heartTone, .dead)
        XCTAssertEqual(dead.heartMotion, .none)
        XCTAssertEqual(dead.waveformMotion, .flatline)

        let blocked = TaskHeartbeatPresentation(status: .blocked, liveness: .inactive)
        XCTAssertEqual(blocked.heartTone, .blocked)
        XCTAssertEqual(blocked.heartMotion, .none)
        XCTAssertEqual(blocked.waveformMotion, .occasionalBlip)

        for status in [TaskVisualStatus.done, .archived] {
            let completed = TaskHeartbeatPresentation(status: status, liveness: .inactive)
            XCTAssertEqual(completed.heartMotion, .none)
            XCTAssertEqual(completed.waveformMotion, .flatline)
        }
    }

    func testNonRunningTaskLivenessIsInactive() {
        let task = KanbanTask(
            id: "done",
            title: "Done",
            status: .done,
            createdAt: Date(timeIntervalSince1970: 1),
            lastHeartbeatAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(task.liveness(at: Date(timeIntervalSince1970: 10_000)), .inactive)
    }

    func testFailedCurrentRunOverridesTaskStatusForDisplay() {
        let task = KanbanTask(
            id: "failed",
            title: "Failed",
            status: .running,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let failedRun = TaskRun(
            id: 7,
            taskID: task.id,
            profile: "rune",
            status: .failed,
            startedAt: Date(timeIntervalSince1970: 110),
            outcome: .gaveUp
        )
        let correlated = makeCorrelated(task: task, currentRun: failedRun)

        XCTAssertEqual(correlated.visualStatus, .failed)
    }

    func testGroupsRootParentWithAllDescendantsAndLeavesStandaloneTaskOnce() {
        let parent = makeCorrelated(task: makeTask(id: "parent"))
        let child = makeCorrelated(task: makeTask(id: "child"))
        let grandchild = makeCorrelated(task: makeTask(id: "grandchild"))
        let standalone = makeCorrelated(task: makeTask(id: "standalone"))
        let links = [
            TaskLink(parentID: parent.id, childID: child.id),
            TaskLink(parentID: child.id, childID: grandchild.id),
            TaskLink(parentID: "missing", childID: standalone.id)
        ]

        let groups = TaskGroupBuilder.groups(
            tasks: [parent, child, grandchild, standalone],
            links: links
        )

        XCTAssertEqual(groups.map(\.parent.id), ["parent", "standalone"])
        XCTAssertEqual(groups[0].children.map(\.id), ["child", "grandchild"])
        XCTAssertFalse(groups[0].isStandalone)
        XCTAssertEqual(groups[0].completedCount, 0)
        XCTAssertEqual(groups[0].totalCount, 3)
        XCTAssertTrue(groups[1].children.isEmpty)
        XCTAssertTrue(groups[1].isStandalone)
        XCTAssertEqual(Set(groups.flatMap { [$0.parent.id] + $0.children.map(\.id) }).count, 4)
    }

    func testGroupProgressCountsDoneAndArchivedTasks() {
        let parent = makeCorrelated(task: makeTask(id: "parent", status: .done))
        let done = makeCorrelated(task: makeTask(id: "done", status: .done))
        let archived = makeCorrelated(task: makeTask(id: "archived", status: .archived))
        let running = makeCorrelated(task: makeTask(id: "running"))

        let group = TaskPresentationGroup(
            parent: parent,
            children: [done, archived, running]
        )

        XCTAssertEqual(group.completedCount, 3)
        XCTAssertEqual(group.totalCount, 4)
    }

    private func makeTask(
        id: String,
        status: KanbanTaskStatus = .running,
        heartbeatAge: TimeInterval? = nil,
        now: Date = Date(timeIntervalSince1970: 1_000)
    ) -> KanbanTask {
        KanbanTask(
            id: id,
            title: id.capitalized,
            status: status,
            createdAt: now.addingTimeInterval(-500),
            lastHeartbeatAt: heartbeatAge.map { now.addingTimeInterval(-$0) }
        )
    }

    private func makeCorrelated(
        task: KanbanTask,
        currentRun: TaskRun? = nil
    ) -> CorrelatedTask {
        CorrelatedTask(
            task: task,
            currentRun: currentRun,
            runConfidence: currentRun == nil ? .notApplicable : .direct,
            session: nil,
            sessionConfidence: .notApplicable,
            parentSession: nil,
            evidence: [],
            workerLogRemotePath: "/home/dhlee/.hermes/kanban/logs/\(task.id).log"
        )
    }
}
