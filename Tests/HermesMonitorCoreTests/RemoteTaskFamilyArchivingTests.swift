import XCTest
@testable import HermesMonitorCore

final class RemoteTaskFamilyArchivingTests: XCTestCase {
    func testRequestUsesDocumentedBoundedMaintenanceContract() throws {
        let request = RemoteTaskFamilyArchiveRequest()

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try TaskFamilyArchiveCodec.encode(request))
                as? [String: Any]
        )
        XCTAssertEqual(object["max_families"] as? Int, 4)
        XCTAssertEqual(object["max_tasks"] as? Int, 32)
        XCTAssertEqual(object["client_source"] as? String, "hermes-monitor")
        XCTAssertEqual(Set(object.keys), ["max_families", "max_tasks", "client_source"])
    }

    func testDecodesStrictTypedArchivedReceipt() throws {
        let data = Data(
            #"{"outcome":"archived","archived_family_count":1,"archived_task_count":2,"archived_task_ids":["t_1234abcd","t_8765abcd"],"deferred_family_count":3,"bounded":true,"reason":null}"#.utf8
        )

        let receipt = try TaskFamilyArchiveCodec.decodeReceipt(data)

        XCTAssertEqual(receipt.outcome, .archived)
        XCTAssertEqual(receipt.archivedFamilyCount, 1)
        XCTAssertEqual(receipt.archivedTaskCount, 2)
        XCTAssertEqual(receipt.archivedTaskIDs, ["t_1234abcd", "t_8765abcd"])
        XCTAssertEqual(receipt.deferredFamilyCount, 3)
        XCTAssertTrue(receipt.bounded)
        XCTAssertNil(receipt.reason)
    }

    func testRejectsUnknownOrInternallyInconsistentReceipt() {
        let invalidReceipts = [
            #"{"outcome":"future","archived_family_count":0,"archived_task_count":0,"archived_task_ids":[],"deferred_family_count":0,"bounded":false,"reason":null}"#,
            #"{"outcome":"archived","archived_family_count":1,"archived_task_count":2,"archived_task_ids":["t_1234abcd"],"deferred_family_count":0,"bounded":false,"reason":null}"#,
            #"{"outcome":"noop","archived_family_count":0,"archived_task_count":0,"archived_task_ids":[],"deferred_family_count":0,"bounded":false,"reason":null,"extra":true}"#,
            #"{"outcome":"rejected","archived_family_count":0,"archived_task_count":0,"archived_task_ids":[],"deferred_family_count":0,"bounded":false,"reason":null}"#,
        ]

        for invalid in invalidReceipts {
            XCTAssertThrowsError(try TaskFamilyArchiveCodec.decodeReceipt(Data(invalid.utf8)))
        }
    }

    func testRemoteCommandUsesFixedCanonicalEnvironmentAndShellQuotesHelper() {
        let command = HermesTaskFamilyArchiveCommand.remoteCommand(
            helper: "print('trusted helper')"
        )

        XCTAssertEqual(
            command,
            "/usr/bin/env HERMES_KANBAN_BOARD=default " +
                "HERMES_KANBAN_DB=/home/dhlee/.hermes/kanban.db " +
                "PYTHONPATH=/home/dhlee/.hermes/hermes-agent " +
                "/home/dhlee/.hermes/hermes-agent/venv/bin/python -c " +
                "'print('\\''trusted helper'\\'')'"
        )
    }

    func testTaskFamilyArchiveHelperIsBundled() {
        XCTAssertNotNil(TaskFamilyArchiveHelperResource.url)
    }

    func testWorkflowRefreshesExactlyOnceAfterArchivedReceipt() async throws {
        let snapshot = makeSnapshot(refreshedAt: Date(timeIntervalSince1970: 2))
        let service = ControlledFamilyArchiveService(
            receipt: makeReceipt(outcome: .archived, archivedTaskIDs: ["t_1234abcd"]),
            refreshResult: .success(snapshot)
        )
        let workflow = RemoteTaskFamilyArchiveWorkflow(archiver: service, refresher: service)

        let result = try await workflow.performMaintenance()
        let operations = await service.operationLog()
        let refreshCalls = await service.refreshCallCount()

        XCTAssertEqual(result.receipt.archivedTaskCount, 1)
        XCTAssertEqual(result.refreshedSnapshot?.refreshedAt, snapshot.refreshedAt)
        XCTAssertEqual(operations, ["archive", "refresh"])
        XCTAssertEqual(refreshCalls, 1)
    }

    func testWorkflowDoesNotRefreshForNoopOrRejectedPreflight() async {
        for outcome in [RemoteTaskFamilyArchiveOutcome.noop, .rejected] {
            let service = ControlledFamilyArchiveService(
                receipt: makeReceipt(outcome: outcome),
                refreshResult: .success(makeSnapshot())
            )
            let workflow = RemoteTaskFamilyArchiveWorkflow(archiver: service, refresher: service)

            do {
                let result = try await workflow.performMaintenance()
                XCTAssertEqual(outcome, .noop)
                XCTAssertNil(result.refreshedSnapshot)
            } catch let error as RemoteTaskFamilyArchiveWorkflowError {
                XCTAssertEqual(outcome, .rejected)
                XCTAssertEqual(error, .preflightRejected)
                XCTAssertTrue(error.localizedDescription.contains("보관"))
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            let refreshCalls = await service.refreshCallCount()
            XCTAssertEqual(refreshCalls, 0)
        }
    }

    func testWorkflowRejectsConcurrentDuplicateRequest() async throws {
        let service = ControlledFamilyArchiveService(
            receipt: makeReceipt(outcome: .noop),
            refreshResult: .success(makeSnapshot()),
            suspendsArchive: true
        )
        let workflow = RemoteTaskFamilyArchiveWorkflow(archiver: service, refresher: service)
        let first = Task { try await workflow.performMaintenance() }
        await service.waitUntilArchiveStarts()

        do {
            _ = try await workflow.performMaintenance()
            XCTFail("Expected duplicate maintenance request to be rejected")
        } catch let error as RemoteTaskFamilyArchiveWorkflowError {
            XCTAssertEqual(error, .alreadyInProgress)
        }

        await service.resumeArchive()
        _ = try await first.value
        let archiveCalls = await service.archiveCallCount()
        let refreshCalls = await service.refreshCallCount()
        XCTAssertEqual(archiveCalls, 1)
        XCTAssertEqual(refreshCalls, 0)
    }

    func testWorkflowReportsKoreanDiagnosticWhenPostArchiveRefreshFails() async {
        let service = ControlledFamilyArchiveService(
            receipt: makeReceipt(outcome: .archived, archivedTaskIDs: ["t_1234abcd"]),
            refreshResult: .failure(FamilyArchiveTestFailure.refreshFailed)
        )
        let workflow = RemoteTaskFamilyArchiveWorkflow(archiver: service, refresher: service)

        do {
            _ = try await workflow.performMaintenance()
            XCTFail("Expected post-maintenance refresh failure")
        } catch let error as RemoteTaskFamilyArchiveWorkflowError {
            XCTAssertEqual(error, .refreshFailedAfterArchive)
            XCTAssertTrue(error.localizedDescription.contains("새로고침"))
            XCTAssertFalse(error.localizedDescription.contains("/"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let refreshCalls = await service.refreshCallCount()
        XCTAssertEqual(refreshCalls, 1)
    }

    private func makeReceipt(
        outcome: RemoteTaskFamilyArchiveOutcome,
        archivedTaskIDs: [String] = []
    ) -> RemoteTaskFamilyArchiveReceipt {
        RemoteTaskFamilyArchiveReceipt(
            outcome: outcome,
            archivedFamilyCount: archivedTaskIDs.isEmpty ? 0 : 1,
            archivedTaskCount: archivedTaskIDs.count,
            archivedTaskIDs: archivedTaskIDs,
            deferredFamilyCount: 0,
            bounded: false,
            reason: outcome == .rejected ? "malformed_graph" : nil
        )
    }

    private func makeSnapshot(
        refreshedAt: Date = Date(timeIntervalSince1970: 1)
    ) -> HermesMonitorSnapshot {
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

private enum FamilyArchiveTestFailure: Error {
    case refreshFailed
}

private actor ControlledFamilyArchiveService: RemoteTaskFamilyArchiving, RemoteSnapshotRefreshing {
    private let receipt: RemoteTaskFamilyArchiveReceipt
    private let refreshResult: Result<HermesMonitorSnapshot, Error>
    private let suspendsArchive: Bool
    private var archiveStarted = false
    private var archiveContinuation: CheckedContinuation<Void, Never>?
    private var archiveCalls = 0
    private var refreshCalls = 0
    private var operations: [String] = []

    init(
        receipt: RemoteTaskFamilyArchiveReceipt,
        refreshResult: Result<HermesMonitorSnapshot, Error>,
        suspendsArchive: Bool = false
    ) {
        self.receipt = receipt
        self.refreshResult = refreshResult
        self.suspendsArchive = suspendsArchive
    }

    func archiveCompletedTaskFamilies(
        _ request: RemoteTaskFamilyArchiveRequest
    ) async throws -> RemoteTaskFamilyArchiveReceipt {
        archiveCalls += 1
        operations.append("archive")
        archiveStarted = true
        if suspendsArchive {
            await withCheckedContinuation { continuation in
                archiveContinuation = continuation
            }
        }
        return receipt
    }

    func refresh() async throws -> HermesMonitorSnapshot {
        refreshCalls += 1
        operations.append("refresh")
        return try refreshResult.get()
    }

    func waitUntilArchiveStarts() async {
        while !archiveStarted { await Task.yield() }
    }

    func resumeArchive() {
        archiveContinuation?.resume()
        archiveContinuation = nil
    }

    func archiveCallCount() -> Int { archiveCalls }
    func refreshCallCount() -> Int { refreshCalls }
    func operationLog() -> [String] { operations }
}
