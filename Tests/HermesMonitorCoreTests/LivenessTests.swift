import XCTest
@testable import HermesMonitorCore

final class LivenessTests: XCTestCase {
    func testLiveSchemaTodoStatusIsRepresentable() {
        XCTAssertEqual(KanbanTaskStatus(rawValue: "todo"), .todo)
    }

    func testRunningTaskBecomesStaleAfterHeartbeatThreshold() {
        let now = Date(timeIntervalSince1970: 1_000)
        let fresh = KanbanTask(
            id: "fresh",
            title: "Fresh",
            status: .running,
            createdAt: now,
            lastHeartbeatAt: now.addingTimeInterval(-179)
        )
        let stale = KanbanTask(
            id: "stale",
            title: "Stale",
            status: .running,
            createdAt: now,
            lastHeartbeatAt: now.addingTimeInterval(-181)
        )

        XCTAssertFalse(fresh.isHeartbeatStale(at: now, threshold: 180))
        XCTAssertTrue(stale.isHeartbeatStale(at: now, threshold: 180))
    }

    func testNonRunningTaskIsNotReportedAsHeartbeatStale() {
        let task = KanbanTask(
            id: "done",
            title: "Done",
            status: .done,
            createdAt: Date(timeIntervalSince1970: 1),
            lastHeartbeatAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertFalse(task.isHeartbeatStale(at: Date(timeIntervalSince1970: 10_000)))
    }
}
