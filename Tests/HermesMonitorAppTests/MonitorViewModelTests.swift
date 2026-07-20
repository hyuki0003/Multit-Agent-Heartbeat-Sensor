import Foundation
import XCTest
@testable import HermesMonitorApp
import HermesMonitorCore

@MainActor
final class MonitorViewModelTests: XCTestCase {
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

    private func makeViewModel(
        service: ControlledMonitorService
    ) -> (MonitorViewModel, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonitorViewModelTests-\(UUID().uuidString)", isDirectory: true)
        let store = ManualSessionLinkStore(
            fileURL: directory.appendingPathComponent("manual-links.json")
        )
        return (
            MonitorViewModel(client: service, manualLinkStore: store),
            directory
        )
    }

    private func makeSnapshot(
        status: KanbanTaskStatus,
        refreshedAt: Date
    ) -> HermesMonitorSnapshot {
        let task = KanbanTask(
            id: "t_b672f7a7",
            title: "Archive fixture",
            status: status,
            createdAt: Date(timeIntervalSince1970: 0),
            completedAt: status == .done || status == .archived ? refreshedAt : nil
        )
        let kanban = KanbanSnapshot(
            tasks: [task],
            runs: [],
            events: [],
            comments: [],
            links: []
        )
        return HermesMonitorSnapshot(
            kanban: kanban,
            state: StateSnapshot(sessions: []),
            tasks: TaskCorrelator().correlate(tasks: [task], runs: [], sessions: []),
            logTails: [:],
            warnings: [],
            refreshedAt: refreshedAt
        )
    }
}

private enum ViewModelTestFailure: Error {
    case missingRefreshResult
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
        authoritativeStatus
    }

    func archiveDoneTask(taskID: String) async throws {
        archiveCalls += 1
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
}
