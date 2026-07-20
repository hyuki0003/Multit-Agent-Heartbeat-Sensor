import Foundation
import XCTest
@testable import HermesMonitorCore

final class RemoteKanbanArchivingTests: XCTestCase {
    func testArchiveCommandPinsCanonicalDefaultDatabaseAndOnlyArchivesValidatedTask() throws {
        let command = try HermesKanbanArchiveCommand.remoteCommand(taskID: "t_b672f7a7")

        XCTAssertEqual(
            command,
            "/usr/bin/env HERMES_KANBAN_BOARD=default " +
                "HERMES_KANBAN_DB=/home/dhlee/.hermes/kanban.db " +
                "/home/dhlee/.hermes/hermes-agent/venv/bin/hermes kanban archive t_b672f7a7"
        )
        XCTAssertFalse(command.contains("--rm"))
        XCTAssertFalse(command.localizedCaseInsensitiveContains("sqlite"))
    }

    func testArchiveCommandRejectsEveryNoncanonicalTaskIDBeforeLaunch() {
        let rejected = [
            "", "t_1", "t_B672F7A7", "t_b672f7ag", "t_b672f7a70", "--rm", "-h",
            "../t_b672f7a7", "t_b672f7a7/child", "t_b672 f7a", "t_b672f7a7\n",
            "t_b672f7a7\0", "'t_b672f7a7'", "t_b672f7a7;id", "$(id)", "작업"
        ]

        for taskID in rejected {
            XCTAssertThrowsError(try HermesKanbanArchiveCommand.remoteCommand(taskID: taskID)) { error in
                XCTAssertEqual(error as? HermesKanbanArchiveError, .invalidTaskID(taskID))
            }
        }
    }

    func testArchiveProcessDeadlineTerminatesAndReapsChild() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        XCTAssertThrowsError(
            try OpenSSHTransport.waitForArchiveProcess(process, timeoutSeconds: 0.05)
        ) { error in
            guard let transportError = error as? OpenSSHTransportError,
                  case .archiveProcessTimedOut(_) = transportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(process.isRunning)
    }

    func testArchiveOutputCaptureDrainsHighVolumeWithoutRetainingMoreThanItsLimit() throws {
        let capture = BoundedProcessOutputCapture(byteLimit: 4_096)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = capture.pipe
        process.standardError = FileHandle.nullDevice

        capture.start()
        try process.run()
        capture.closeParentWriteEnd()
        Thread.sleep(forTimeInterval: 0.05)
        process.terminate()
        process.waitUntilExit()

        let captured = capture.finish()
        XCTAssertEqual(captured.count, 4_096)
    }

    func testArchiveDiagnosticsAreBoundedAndRedactCredentialSecretBeforeTruncation() {
        let credentialSentinel = "fixture-value-that-must-be-redacted"
        let output = Data(
            (String(repeating: "x", count: 7_000) + credentialSentinel +
                String(repeating: "z", count: 9_000)).utf8
        )
        let error = Data("failure: \(credentialSentinel)\n".utf8)

        let diagnostics = OpenSSHTransport.archiveDiagnostics(
            output: output,
            error: error,
            secret: credentialSentinel
        )

        XCTAssertFalse(diagnostics.contains(credentialSentinel))
        XCTAssertTrue(diagnostics.contains("<redacted>"))
        XCTAssertLessThanOrEqual(diagnostics.utf8.count, 8 * 1_024)
    }

    func testArchiveDiagnosticsRedactSecretCrossingFormerPerStreamBoundary() {
        let credentialSentinel = "boundary-secret-must-be-redacted"
        let exposedPrefix = String(credentialSentinel.prefix(6))
        let output = Data(
            (String(repeating: "x", count: (4 * 1_024) - exposedPrefix.utf8.count) +
                credentialSentinel + " trailing diagnostics").utf8
        )

        let diagnostics = OpenSSHTransport.archiveDiagnostics(
            output: output,
            error: Data(),
            secret: credentialSentinel
        )

        XCTAssertTrue(diagnostics.contains("<redacted>"))
        XCTAssertFalse(diagnostics.contains(credentialSentinel))
        XCTAssertFalse(diagnostics.contains(exposedPrefix))
        XCTAssertLessThanOrEqual(diagnostics.utf8.count, 8 * 1_024)
    }

    func testArchiveWorkflowRefreshesExactlyOnceOnlyAfterRemoteSuccess() async throws {
        let expected = makeSnapshot(refreshedAt: Date(timeIntervalSince1970: 2))
        let service = FakeMonitorService(refreshResult: .success(expected))
        let workflow = RemoteArchiveWorkflow(service: service)

        let actual = try await workflow.archiveAndRefresh(taskID: "t_b672f7a7")
        let archivedTaskIDs = await service.archivedTaskIDs()
        let refreshCallCount = await service.refreshCallCount()
        let operationLog = await service.operationLog()

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(archivedTaskIDs, ["t_b672f7a7"])
        XCTAssertEqual(refreshCallCount, 1)
        XCTAssertEqual(
            operationLog,
            ["status:t_b672f7a7", "archive:t_b672f7a7", "refresh"]
        )
    }

    func testArchiveWorkflowRejectsTaskThatIsNoLongerAuthoritativelyDone() async {
        let service = FakeMonitorService(
            authoritativeStatus: .running,
            refreshResult: .success(makeSnapshot())
        )
        let workflow = RemoteArchiveWorkflow(service: service)

        do {
            _ = try await workflow.archiveAndRefresh(taskID: "t_b672f7a7")
            XCTFail("Expected authoritative status conflict")
        } catch let error as RemoteArchiveWorkflowError {
            XCTAssertEqual(
                error,
                .taskNoLongerDone(taskID: "t_b672f7a7", status: .running)
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let archivedTaskIDs = await service.archivedTaskIDs()
        let refreshCallCount = await service.refreshCallCount()
        let operationLog = await service.operationLog()
        XCTAssertTrue(archivedTaskIDs.isEmpty)
        XCTAssertEqual(refreshCallCount, 0)
        XCTAssertEqual(operationLog, ["status:t_b672f7a7"])
    }

    func testArchiveWorkflowDoesNotRefreshAfterRemoteFailureOrTimeout() async {
        let failures: [Error] = [
            TestFailure.archiveRejected,
            OpenSSHTransportError.archiveProcessTimedOut(timeoutSeconds: 20)
        ]
        for failure in failures {
            let service = FakeMonitorService(
                archiveError: failure,
                refreshResult: .success(makeSnapshot())
            )
            let workflow = RemoteArchiveWorkflow(service: service)

            do {
                _ = try await workflow.archiveAndRefresh(taskID: "t_b672f7a7")
                XCTFail("Expected remote archive failure")
            } catch {
                // Expected: the original archive error remains actionable.
            }
            let refreshCallCount = await service.refreshCallCount()
            XCTAssertEqual(refreshCallCount, 0)
        }
    }

    func testArchiveWorkflowDistinguishesRefreshFailureAfterRemoteSuccess() async {
        let service = FakeMonitorService(refreshResult: .failure(TestFailure.refreshRejected))
        let workflow = RemoteArchiveWorkflow(service: service)

        do {
            _ = try await workflow.archiveAndRefresh(taskID: "t_b672f7a7")
            XCTFail("Expected post-archive refresh failure")
        } catch let error as RemoteArchiveWorkflowError {
            guard case .refreshFailedAfterArchive(let message) = error else {
                return XCTFail("Unexpected workflow error: \(error)")
            }
            XCTAssertTrue(message.contains("refresh rejected"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let archivedTaskIDs = await service.archivedTaskIDs()
        let refreshCallCount = await service.refreshCallCount()
        XCTAssertEqual(archivedTaskIDs, ["t_b672f7a7"])
        XCTAssertEqual(refreshCallCount, 1)
    }

    func testArchiveWorkflowRejectsDuplicateTaskWhileFirstRequestIsInFlight() async throws {
        let service = SuspendingMonitorService(snapshot: makeSnapshot())
        let workflow = RemoteArchiveWorkflow(service: service)
        let first = Task {
            try await workflow.archiveAndRefresh(taskID: "t_b672f7a7")
        }
        await service.waitUntilArchiveStarts()

        do {
            _ = try await workflow.archiveAndRefresh(taskID: "t_b672f7a7")
            XCTFail("Expected duplicate request to be rejected")
        } catch let error as RemoteArchiveWorkflowError {
            XCTAssertEqual(error, .alreadyInProgress(taskID: "t_b672f7a7"))
        }

        await service.resumeArchive()
        _ = try await first.value
        let refreshCallCount = await service.refreshCallCount()
        XCTAssertEqual(refreshCallCount, 1)
    }

    private func makeSnapshot(refreshedAt: Date = Date(timeIntervalSince1970: 1)) -> HermesMonitorSnapshot {
        HermesMonitorSnapshot(
            kanban: KanbanSnapshot(tasks: [], runs: [], events: [], comments: [], links: []),
            state: StateSnapshot(sessions: []),
            tasks: [],
            logTails: [:],
            warnings: [],
            refreshedAt: refreshedAt
        )
    }
}

private enum TestFailure: Error, LocalizedError {
    case archiveRejected
    case refreshRejected

    var errorDescription: String? {
        switch self {
        case .archiveRejected: return "archive rejected"
        case .refreshRejected: return "refresh rejected"
        }
    }
}

private actor FakeMonitorService: HermesMonitorServing {
    private let authoritativeStatus: KanbanTaskStatus?
    private let archiveError: Error?
    private let refreshResult: Result<HermesMonitorSnapshot, Error>
    private var archiveCalls: [String] = []
    private var refreshCalls = 0
    private var operations: [String] = []

    init(
        authoritativeStatus: KanbanTaskStatus? = .done,
        archiveError: Error? = nil,
        refreshResult: Result<HermesMonitorSnapshot, Error>
    ) {
        self.authoritativeStatus = authoritativeStatus
        self.archiveError = archiveError
        self.refreshResult = refreshResult
    }

    func authoritativeTaskStatus(taskID: String) async throws -> KanbanTaskStatus? {
        operations.append("status:\(taskID)")
        return authoritativeStatus
    }

    func archiveDoneTask(taskID: String) async throws {
        operations.append("archive:\(taskID)")
        archiveCalls.append(taskID)
        if let archiveError { throw archiveError }
    }

    func refresh() async throws -> HermesMonitorSnapshot {
        operations.append("refresh")
        refreshCalls += 1
        return try refreshResult.get()
    }

    func archivedTaskIDs() -> [String] { archiveCalls }
    func refreshCallCount() -> Int { refreshCalls }
    func operationLog() -> [String] { operations }
}

private actor SuspendingMonitorService: HermesMonitorServing {
    private let snapshot: HermesMonitorSnapshot
    private var archiveStarted = false
    private var archiveContinuation: CheckedContinuation<Void, Never>?
    private var refreshCalls = 0

    init(snapshot: HermesMonitorSnapshot) {
        self.snapshot = snapshot
    }

    func authoritativeTaskStatus(taskID: String) async throws -> KanbanTaskStatus? {
        .done
    }

    func archiveDoneTask(taskID: String) async throws {
        archiveStarted = true
        await withCheckedContinuation { continuation in
            archiveContinuation = continuation
        }
    }

    func refresh() async throws -> HermesMonitorSnapshot {
        refreshCalls += 1
        return snapshot
    }

    func waitUntilArchiveStarts() async {
        while !archiveStarted { await Task.yield() }
    }

    func resumeArchive() {
        archiveContinuation?.resume()
        archiveContinuation = nil
    }

    func refreshCallCount() -> Int { refreshCalls }
}
