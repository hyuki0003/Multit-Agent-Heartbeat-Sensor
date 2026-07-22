import Foundation
import XCTest
@testable import HermesMonitorApp
import HermesMonitorCore

@MainActor
final class MonitorViewModelTests: XCTestCase {
    func testAutomaticArchiveDoesNotRunWhenDisabled() async throws {
        let initial = makeSnapshot(status: .done, refreshedAt: Date(timeIntervalSince1970: 1))
        let service = ControlledMonitorService(
            authoritativeStatus: .done,
            refreshResults: [.success(initial)]
        )
        let (viewModel, directory) = makeViewModel(
            service: service,
            automaticallyArchiveDoneTasks: { false }
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        await viewModel.refresh()

        let archiveCalls = await service.archiveCallCount()
        let refreshCalls = await service.refreshCallCount()
        XCTAssertEqual(archiveCalls, 0)
        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(viewModel.snapshot?.refreshedAt, initial.refreshedAt)
    }

    func testAutomaticArchiveRunsForDoneTaskWhenEnabled() async throws {
        let initial = makeSnapshot(status: .done, refreshedAt: Date(timeIntervalSince1970: 1))
        let archived = makeSnapshot(status: .archived, refreshedAt: Date(timeIntervalSince1970: 2))
        let service = ControlledMonitorService(
            authoritativeStatus: .done,
            refreshResults: [.success(initial), .success(archived)]
        )
        let (viewModel, directory) = makeViewModel(
            service: service,
            automaticallyArchiveDoneTasks: { true }
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        await viewModel.refresh()

        let archiveCalls = await service.archiveCallCount()
        let refreshCalls = await service.refreshCallCount()
        XCTAssertEqual(archiveCalls, 1)
        XCTAssertEqual(refreshCalls, 2)
        XCTAssertEqual(viewModel.snapshot?.refreshedAt, archived.refreshedAt)
    }

    func testAutomaticArchiveProcessesRefreshedDoneTasksSeriallyWithoutDuplicates() async {
        let firstID = "t_11111111"
        let secondID = "t_22222222"
        let initial = makeSnapshot(
            tasks: [(firstID, .done), (secondID, .done)],
            refreshedAt: Date(timeIntervalSince1970: 1)
        )
        let afterFirstArchive = makeSnapshot(
            tasks: [(firstID, .archived), (secondID, .done)],
            refreshedAt: Date(timeIntervalSince1970: 2)
        )
        let afterSecondArchive = makeSnapshot(
            tasks: [(firstID, .archived), (secondID, .archived)],
            refreshedAt: Date(timeIntervalSince1970: 3)
        )
        let service = ControlledMonitorService(
            authoritativeStatus: .done,
            refreshResults: [
                .success(initial),
                .success(afterFirstArchive),
                .success(afterSecondArchive),
            ]
        )
        let (viewModel, directory) = makeViewModel(
            service: service,
            automaticallyArchiveDoneTasks: { true }
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        await viewModel.refresh()

        let operations = await service.operationLog()
        XCTAssertEqual(
            operations,
            [
                "refresh",
                "status:\(firstID)",
                "archive:\(firstID)",
                "refresh",
                "status:\(secondID)",
                "archive:\(secondID)",
                "refresh",
            ]
        )
        XCTAssertEqual(viewModel.snapshot?.refreshedAt, afterSecondArchive.refreshedAt)
        XCTAssertTrue(viewModel.archiveInFlightTaskIDs.isEmpty)
    }

    func testAutomaticArchiveUnknownOutcomesSuppressSessionRetriesAndStayNonRetryable() async {
        let unknownOutcomes: [(String, Error)] = [
            (
                "timeout",
                OpenSSHTransportError.archiveProcessTimedOut(timeoutSeconds: 20)
            ),
            ("cancellation", CancellationError()),
        ]

        for (name, error) in unknownOutcomes {
            let initial = makeSnapshot(
                status: .done,
                refreshedAt: Date(timeIntervalSince1970: 1)
            )
            let service = ControlledMonitorService(
                authoritativeStatus: .done,
                archiveError: error,
                refreshResults: [.success(initial), .success(initial)]
            )
            let (viewModel, directory) = makeViewModel(
                service: service,
                automaticallyArchiveDoneTasks: { true }
            )
            defer { try? FileManager.default.removeItem(at: directory) }

            await viewModel.refresh()
            await viewModel.refresh()

            let archiveCalls = await service.archiveCallCount()
            XCTAssertEqual(archiveCalls, 1, name)
            XCTAssertEqual(viewModel.archiveFailure?.canRetry, false, name)
            XCTAssertTrue(
                viewModel.archiveFailure?.message.localizedCaseInsensitiveContains(
                    "outcome is unknown"
                ) == true,
                name
            )
            XCTAssertTrue(viewModel.canArchiveTasks, name)
            XCTAssertFalse(viewModel.isRefreshing, name)
        }
    }

    func testAutomaticArchiveOrdinaryFailureSuppressesAutoRetryButAllowsManualRetry() async {
        let initial = makeSnapshot(status: .done, refreshedAt: Date(timeIntervalSince1970: 1))
        let service = ControlledMonitorService(
            authoritativeStatus: .done,
            archiveError: ViewModelTestFailure.archiveFailed,
            refreshResults: [.success(initial), .success(initial)]
        )
        let (viewModel, directory) = makeViewModel(
            service: service,
            automaticallyArchiveDoneTasks: { true }
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        await viewModel.refresh()
        await viewModel.refresh()

        let automaticArchiveCalls = await service.archiveCallCount()
        XCTAssertEqual(automaticArchiveCalls, 1)
        XCTAssertEqual(viewModel.archiveFailure?.canRetry, true)
        XCTAssertTrue(viewModel.archiveFailure?.message.contains("No task record was deleted") == true)

        await viewModel.retryArchive()

        let archiveCallsAfterManualRetry = await service.archiveCallCount()
        XCTAssertEqual(archiveCallsAfterManualRetry, 2)
        XCTAssertEqual(viewModel.archiveFailure?.canRetry, true)
    }

    func testAutomaticArchiveNeverSubmitsNonDoneTasks() async {
        for status in KanbanTaskStatus.allCases where status != .done {
            let snapshot = makeSnapshot(
                status: status,
                refreshedAt: Date(timeIntervalSince1970: 1)
            )
            let service = ControlledMonitorService(
                authoritativeStatus: status,
                refreshResults: [.success(snapshot)]
            )
            let (viewModel, directory) = makeViewModel(
                service: service,
                automaticallyArchiveDoneTasks: { true }
            )
            defer { try? FileManager.default.removeItem(at: directory) }

            await viewModel.refresh()

            let archiveCalls = await service.archiveCallCount()
            let operations = await service.operationLog()
            XCTAssertEqual(archiveCalls, 0, status.rawValue)
            XCTAssertEqual(operations, ["refresh"], status.rawValue)
        }
    }

    func testAutomaticArchiveReportsAuthoritativeStatusChangeOnceWithoutMutation() async {
        let initial = makeSnapshot(status: .done, refreshedAt: Date(timeIntervalSince1970: 1))
        let service = ControlledMonitorService(
            authoritativeStatus: .running,
            refreshResults: [.success(initial), .success(initial)]
        )
        let (viewModel, directory) = makeViewModel(
            service: service,
            automaticallyArchiveDoneTasks: { true }
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        await viewModel.refresh()
        await viewModel.refresh()

        let archiveCalls = await service.archiveCallCount()
        let operations = await service.operationLog()
        XCTAssertEqual(archiveCalls, 0)
        XCTAssertEqual(
            operations,
            ["refresh", "status:t_b672f7a7", "refresh"]
        )
        XCTAssertEqual(
            viewModel.archiveFailure?.message,
            "Task is no longer Done; it was not removed. Refresh to review its current status."
        )
        XCTAssertEqual(viewModel.archiveFailure?.canRetry, false)
    }

    func testArchiveSerializesManualRefreshAndPublishesOnlyPostArchiveSnapshot() async throws {
        let initial = makeSnapshot(status: .done, refreshedAt: Date(timeIntervalSince1970: 1))
        let archived = makeSnapshot(status: .archived, refreshedAt: Date(timeIntervalSince1970: 2))
        let service = ControlledMonitorService(
            authoritativeStatus: .done,
            refreshResults: [.success(initial), .success(archived)],
            suspendsArchive: true
        )
        let (viewModel, directory) = makeViewModel(service: service)
        defer { try? FileManager.default.removeItem(at: directory) }

        await viewModel.refresh()
        let requestedTask = try XCTUnwrap(viewModel.snapshot?.tasks.first)
        let archiveTask = Task { @MainActor in
            await viewModel.archiveDoneTask(requestedTask)
        }
        await service.waitUntilArchiveStarts()

        XCTAssertTrue(viewModel.isRefreshing)
        XCTAssertEqual(viewModel.archiveInFlightTaskIDs, Set([requestedTask.id]))
        XCTAssertEqual(viewModel.snapshot?.refreshedAt, initial.refreshedAt)

        await viewModel.refresh()
        let refreshCallsDuringArchive = await service.refreshCallCount()
        XCTAssertEqual(refreshCallsDuringArchive, 1)
        XCTAssertEqual(viewModel.snapshot?.refreshedAt, initial.refreshedAt)

        await service.resumeArchive()
        await archiveTask.value

        let finalRefreshCalls = await service.refreshCallCount()
        XCTAssertEqual(finalRefreshCalls, 2)
        XCTAssertEqual(viewModel.snapshot?.refreshedAt, archived.refreshedAt)
        XCTAssertEqual(viewModel.archiveNotice, "Removed from active board — archived on server.")
        XCTAssertFalse(viewModel.isRefreshing)
        XCTAssertTrue(viewModel.archiveInFlightTaskIDs.isEmpty)
    }

    func testArchiveRejectsAuthoritativeStatusChangeWithoutMutation() async throws {
        let initial = makeSnapshot(status: .done, refreshedAt: Date(timeIntervalSince1970: 1))
        let service = ControlledMonitorService(
            authoritativeStatus: .running,
            refreshResults: [.success(initial)]
        )
        let (viewModel, directory) = makeViewModel(service: service)
        defer { try? FileManager.default.removeItem(at: directory) }

        await viewModel.refresh()
        let requestedTask = try XCTUnwrap(viewModel.snapshot?.tasks.first)
        await viewModel.archiveDoneTask(requestedTask)

        let archiveCalls = await service.archiveCallCount()
        XCTAssertEqual(archiveCalls, 0)
        XCTAssertEqual(viewModel.snapshot?.refreshedAt, initial.refreshedAt)
        XCTAssertEqual(
            viewModel.archiveFailure?.message,
            "Task is no longer Done; it was not removed. Refresh to review its current status."
        )
        XCTAssertEqual(viewModel.archiveFailure?.canRetry, false)
    }

    func testArchiveTimeoutReportsUnknownRemoteOutcomeWithoutAutomaticRetry() async throws {
        let initial = makeSnapshot(status: .done, refreshedAt: Date(timeIntervalSince1970: 1))
        let service = ControlledMonitorService(
            authoritativeStatus: .done,
            archiveError: OpenSSHTransportError.archiveProcessTimedOut(timeoutSeconds: 20),
            refreshResults: [.success(initial)]
        )
        let (viewModel, directory) = makeViewModel(service: service)
        defer { try? FileManager.default.removeItem(at: directory) }

        await viewModel.refresh()
        let requestedTask = try XCTUnwrap(viewModel.snapshot?.tasks.first)
        await viewModel.archiveDoneTask(requestedTask)

        let refreshCalls = await service.refreshCallCount()
        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(viewModel.snapshot?.refreshedAt, initial.refreshedAt)
        XCTAssertEqual(viewModel.archiveFailure?.canRetry, false)
        XCTAssertTrue(
            viewModel.archiveFailure?.message.localizedCaseInsensitiveContains(
                "remote outcome is unknown"
            ) == true
        )
    }

    func testAcceptedInstructionRefreshesTimelineAndPublishesReceiptNotice() async throws {
        let initial = makeSnapshot(status: .blocked, refreshedAt: Date(timeIntervalSince1970: 1))
        let refreshed = makeSnapshot(status: .blocked, refreshedAt: Date(timeIntervalSince1970: 2))
        let service = ControlledMonitorService(
            authoritativeStatus: .blocked,
            refreshResults: [.success(initial), .success(refreshed)]
        )
        let submitter = ControlledInstructionSubmitter(
            receipt: RemoteTaskInstructionReceipt(
                accepted: true,
                duplicate: false,
                instructionID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                sourceCommentID: 41,
                envelopeTaskID: "t_abcdef12"
            )
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonitorViewModelTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let viewModel = MonitorViewModel(
            client: service,
            instructionSubmitter: submitter,
            manualLinkStore: ManualSessionLinkStore(
                fileURL: directory.appendingPathComponent("manual-links.json")
            )
        )
        await viewModel.refresh()
        let request = try RemoteTaskInstructionRequest(
            taskID: "t_b672f7a7",
            message: "선택지 B로 진행해 주세요.",
            instructionID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            selectedOptionID: "B"
        )

        let accepted = await viewModel.submitTaskInstruction(request)

        XCTAssertTrue(accepted)
        let submittedRequests = await submitter.submittedRequests()
        XCTAssertEqual(submittedRequests, [request])
        XCTAssertEqual(viewModel.snapshot?.refreshedAt, refreshed.refreshedAt)
        XCTAssertEqual(
            viewModel.instructionNoticeByTaskID[request.taskID],
            "Astra instruction accepted · comment #41 · envelope t_abcdef12"
        )
        XCTAssertNil(viewModel.instructionErrorByTaskID[request.taskID])
        XCTAssertFalse(viewModel.instructionInFlightTaskIDs.contains(request.taskID))
    }

    private func makeViewModel(
        service: ControlledMonitorService,
        automaticallyArchiveDoneTasks: @escaping @MainActor () -> Bool = { false }
    ) -> (MonitorViewModel, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonitorViewModelTests-\(UUID().uuidString)", isDirectory: true)
        let store = ManualSessionLinkStore(
            fileURL: directory.appendingPathComponent("manual-links.json")
        )
        return (
            MonitorViewModel(
                client: service,
                manualLinkStore: store,
                automaticallyArchiveDoneTasks: automaticallyArchiveDoneTasks
            ),
            directory
        )
    }

    private func makeSnapshot(
        status: KanbanTaskStatus,
        refreshedAt: Date
    ) -> HermesMonitorSnapshot {
        makeSnapshot(
            tasks: [("t_b672f7a7", status)],
            refreshedAt: refreshedAt
        )
    }

    private func makeSnapshot(
        tasks taskStatuses: [(String, KanbanTaskStatus)],
        refreshedAt: Date
    ) -> HermesMonitorSnapshot {
        let tasks = taskStatuses.map { taskID, status in
            KanbanTask(
                id: taskID,
                title: "Archive fixture \(taskID)",
                status: status,
                createdAt: Date(timeIntervalSince1970: 0),
                completedAt: status == .done || status == .archived ? refreshedAt : nil
            )
        }
        let kanban = KanbanSnapshot(
            tasks: tasks,
            runs: [],
            events: [],
            comments: [],
            links: []
        )
        return HermesMonitorSnapshot(
            kanban: kanban,
            state: StateSnapshot(sessions: []),
            tasks: TaskCorrelator().correlate(tasks: tasks, runs: [], sessions: []),
            logTails: [:],
            warnings: [],
            refreshedAt: refreshedAt
        )
    }
}

private actor ControlledInstructionSubmitter: RemoteTaskInstructionSubmitting {
    private let receipt: RemoteTaskInstructionReceipt
    private var requests: [RemoteTaskInstructionRequest] = []

    init(receipt: RemoteTaskInstructionReceipt) {
        self.receipt = receipt
    }

    func submitTaskInstruction(
        _ request: RemoteTaskInstructionRequest
    ) async throws -> RemoteTaskInstructionReceipt {
        requests.append(request)
        return receipt
    }

    func submittedRequests() -> [RemoteTaskInstructionRequest] {
        requests
    }
}

private enum ViewModelTestFailure: Error {
    case missingRefreshResult
    case archiveFailed
}

private actor ControlledMonitorService: HermesMonitorServing {
    private let authoritativeStatus: KanbanTaskStatus?
    private let archiveError: Error?
    private var refreshResults: [Result<HermesMonitorSnapshot, Error>]
    private let suspendsArchive: Bool
    private var archiveStarted = false
    private var archiveContinuation: CheckedContinuation<Void, Never>?
    private var refreshCalls = 0
    private var archiveCalls = 0
    private var operations: [String] = []

    init(
        authoritativeStatus: KanbanTaskStatus?,
        archiveError: Error? = nil,
        refreshResults: [Result<HermesMonitorSnapshot, Error>],
        suspendsArchive: Bool = false
    ) {
        self.authoritativeStatus = authoritativeStatus
        self.archiveError = archiveError
        self.refreshResults = refreshResults
        self.suspendsArchive = suspendsArchive
    }

    func authoritativeTaskStatus(taskID: String) async throws -> KanbanTaskStatus? {
        operations.append("status:\(taskID)")
        return authoritativeStatus
    }

    func archiveDoneTask(taskID: String) async throws {
        archiveCalls += 1
        operations.append("archive:\(taskID)")
        archiveStarted = true
        if suspendsArchive {
            await withCheckedContinuation { continuation in
                archiveContinuation = continuation
            }
        }
        if let archiveError { throw archiveError }
    }

    func refresh() async throws -> HermesMonitorSnapshot {
        refreshCalls += 1
        operations.append("refresh")
        guard !refreshResults.isEmpty else { throw ViewModelTestFailure.missingRefreshResult }
        return try refreshResults.removeFirst().get()
    }

    func waitUntilArchiveStarts() async {
        while !archiveStarted { await Task.yield() }
    }

    func resumeArchive() {
        archiveContinuation?.resume()
        archiveContinuation = nil
    }

    func refreshCallCount() -> Int { refreshCalls }
    func archiveCallCount() -> Int { archiveCalls }
    func operationLog() -> [String] { operations }
}
