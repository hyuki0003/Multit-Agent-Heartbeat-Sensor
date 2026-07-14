import XCTest
@testable import HermesMonitorCore

final class RemotePathPolicyTests: XCTestCase {
    func testAllowsOnlyApprovedDatabaseAndTaskLogPaths() throws {
        let policy = RemotePathPolicy()

        XCTAssertNoThrow(try policy.validateDatabasePath(RemotePathPolicy.kanbanDatabase))
        XCTAssertNoThrow(try policy.validateDatabasePath(RemotePathPolicy.stateDatabase))
        XCTAssertEqual(
            try policy.workerLogPath(taskID: "t_70b1936d"),
            "/home/dhlee/.hermes/kanban/logs/t_70b1936d.log"
        )
    }

    func testRejectsUnapprovedPathsAndTraversal() {
        let policy = RemotePathPolicy()

        XCTAssertThrowsError(try policy.validateDatabasePath("/etc/passwd"))
        XCTAssertThrowsError(try policy.workerLogPath(taskID: "../state"))
        XCTAssertThrowsError(try policy.workerLogPath(taskID: "task/child"))
    }
}
