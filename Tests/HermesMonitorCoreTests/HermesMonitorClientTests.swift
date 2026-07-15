import XCTest
@testable import HermesMonitorCore

final class HermesMonitorClientTests: XCTestCase {
    func testWorkerLogsAreRequestedOnlyForRunningTasks() {
        let now = Date(timeIntervalSince1970: 1_000)
        let tasks = [
            task(id: "done", status: .done, now: now),
            task(id: "running-b", status: .running, now: now),
            task(id: "blocked", status: .blocked, now: now),
            task(id: "running-a", status: .running, now: now)
        ]

        XCTAssertEqual(
            HermesMonitorClient.workerLogTaskIDs(for: tasks),
            ["running-a", "running-b"]
        )
    }

    func testRefreshBackoffGrowsAfterFailuresAndResetsAfterSuccess() {
        let backoff = MonitorRefreshBackoff(baseDelay: 10, maximumDelay: 60)

        XCTAssertEqual(backoff.delay(afterConsecutiveFailures: 0), 10)
        XCTAssertEqual(backoff.delay(afterConsecutiveFailures: 1), 20)
        XCTAssertEqual(backoff.delay(afterConsecutiveFailures: 2), 40)
        XCTAssertEqual(backoff.delay(afterConsecutiveFailures: 3), 60)
        XCTAssertEqual(backoff.delay(afterConsecutiveFailures: 20), 60)
        XCTAssertEqual(backoff.delay(afterConsecutiveFailures: 0), 10)
        XCTAssertEqual(
            backoff.delay(afterConsecutiveFailures: 1, elapsed: 120),
            20,
            "A slow failed poll must still sleep before retrying"
        )
        XCTAssertEqual(backoff.delay(afterConsecutiveFailures: 0, elapsed: 12), 0)
    }

    private func task(id: String, status: KanbanTaskStatus, now: Date) -> KanbanTask {
        KanbanTask(
            id: id,
            title: id,
            status: status,
            createdAt: now,
            lastHeartbeatAt: status == .running ? now : nil
        )
    }
}
