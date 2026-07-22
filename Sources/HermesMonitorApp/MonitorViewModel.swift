import Combine
import Foundation
#if canImport(HermesMonitorCore)
import HermesMonitorCore
#endif

struct TaskArchiveFailure: Identifiable {
    let id = UUID()
    let task: CorrelatedTask
    let message: String
    let canRetry: Bool
}

@MainActor
final class MonitorViewModel: ObservableObject {
    @Published private(set) var snapshot: HermesMonitorSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var connectionState: MonitorConnectionState
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var selectedTaskID: String?
    @Published private(set) var archiveInFlightTaskIDs: Set<String> = []
    @Published private(set) var archiveFailure: TaskArchiveFailure?
    @Published private(set) var archiveNotice: String?
    @Published private(set) var instructionInFlightTaskIDs: Set<String> = []
    @Published private(set) var instructionNoticeByTaskID: [String: String] = [:]
    @Published private(set) var instructionErrorByTaskID: [String: String] = [:]

    private let client: (any HermesMonitorServing)?
    private let archiveWorkflow: RemoteArchiveWorkflow?
    private let instructionSubmitter: (any RemoteTaskInstructionSubmitting)?
    private let manualLinkStore: ManualSessionLinkStore
    private let automaticallyArchiveDoneTasks: @MainActor () -> Bool
    private var manualSessionLinks: [String: String]
    private var monitoringTask: Task<Void, Never>?
    private var persistentErrorMessage: String?
    private var automaticArchiveAttemptedTaskIDs: Set<String> = []
    var onSnapshot: ((HermesMonitorSnapshot) -> Void)?
    var canArchiveTasks: Bool { archiveWorkflow != nil }
    var canSubmitTaskInstructions: Bool { instructionSubmitter != nil }

    init(
        client: (any HermesMonitorServing)?,
        instructionSubmitter: (any RemoteTaskInstructionSubmitting)? = nil,
        initialError: String? = nil,
        manualLinkStore: ManualSessionLinkStore = ManualSessionLinkStore(
            fileURL: ManualSessionLinkStore.defaultFileURL()
        ),
        automaticallyArchiveDoneTasks: @escaping @MainActor () -> Bool = { false }
    ) {
        self.client = client
        self.archiveWorkflow = client.map { RemoteArchiveWorkflow(service: $0) }
        self.instructionSubmitter = instructionSubmitter ??
            (client as? any RemoteTaskInstructionSubmitting)
        self.manualLinkStore = manualLinkStore
        self.automaticallyArchiveDoneTasks = automaticallyArchiveDoneTasks
        self.errorMessage = initialError
        self.connectionState = client == nil ? .disconnected : .connecting
        self.persistentErrorMessage = nil

        do {
            self.manualSessionLinks = try manualLinkStore.load()
        } catch {
            self.manualSessionLinks = [:]
            let message = "Could not load manual links: \(error.localizedDescription)"
            self.errorMessage = [initialError, message]
                .compactMap { $0 }
                .joined(separator: "\n")
        }
    }

    func startMonitoring(
        interval: @escaping @MainActor () -> TimeInterval = { 10 }
    ) {
        guard monitoringTask == nil else { return }
        monitoringTask = Task { [weak self] in
            var consecutiveFailures = 0
            while !Task.isCancelled {
                guard let self else { return }
                let refreshStartedAt = Date()
                let succeeded = await self.performRefresh()
                consecutiveFailures = succeeded ? 0 : consecutiveFailures + 1
                let baseInterval = min(max(interval(), 2), 300)
                let backoff = MonitorRefreshBackoff(
                    baseDelay: baseInterval,
                    maximumDelay: 300
                )
                let elapsed = Date().timeIntervalSince(refreshStartedAt)
                let delay = backoff.delay(
                    afterConsecutiveFailures: consecutiveFailures,
                    elapsed: elapsed
                )
                let nanoseconds = UInt64(delay * 1_000_000_000)
                if nanoseconds == 0 {
                    await Task.yield()
                    continue
                }
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    func refresh() async {
        _ = await performRefresh()
    }

    private func performRefresh() async -> Bool {
        guard let client else {
            connectionState = .disconnected
            return false
        }
        guard !isRefreshing else { return true }
        isRefreshing = true
        if snapshot == nil {
            connectionState = .connecting
        }
        defer { isRefreshing = false }

        do {
            let refreshedSnapshot = try await client.refresh()
            apply(refreshedSnapshot)
            await archiveDoneTasksAutomaticallyIfNeeded()
            return true
        } catch {
            connectionState = .failed
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func archiveDoneTasksAutomaticallyIfNeeded() async {
        guard let archiveWorkflow else { return }

        while automaticallyArchiveDoneTasks() {
            guard let task = snapshot?.tasks.first(where: {
                $0.task.status == .done &&
                    !automaticArchiveAttemptedTaskIDs.contains($0.id)
            }) else {
                return
            }

            automaticArchiveAttemptedTaskIDs.insert(task.id)
            archiveInFlightTaskIDs.insert(task.id)

            do {
                let refreshedSnapshot = try await archiveWorkflow.archiveAndRefresh(taskID: task.id)
                archiveInFlightTaskIDs.remove(task.id)
                apply(refreshedSnapshot)
            } catch {
                archiveInFlightTaskIDs.remove(task.id)
                recordArchiveFailure(error, for: task)
            }
        }
    }

    func archiveDoneTask(_ requestedTask: CorrelatedTask) async {
        guard let archiveWorkflow else { return }
        guard !isRefreshing,
              !archiveInFlightTaskIDs.contains(requestedTask.id) else { return }
        guard snapshot?.tasks.first(where: { $0.id == requestedTask.id })?.task.status == .done else {
            archiveFailure = TaskArchiveFailure(
                task: requestedTask,
                message: "Task is no longer Done; it was not removed. Refresh to review its current status.",
                canRetry: false
            )
            return
        }

        isRefreshing = true
        archiveInFlightTaskIDs.insert(requestedTask.id)
        archiveFailure = nil
        archiveNotice = nil
        defer {
            archiveInFlightTaskIDs.remove(requestedTask.id)
            isRefreshing = false
        }

        do {
            let refreshedSnapshot = try await archiveWorkflow.archiveAndRefresh(taskID: requestedTask.id)
            apply(refreshedSnapshot)
            archiveNotice = "Removed from active board — archived on server."
        } catch {
            recordArchiveFailure(error, for: requestedTask)
        }
    }

    func submitTaskInstruction(_ request: RemoteTaskInstructionRequest) async -> Bool {
        guard let instructionSubmitter,
              !instructionInFlightTaskIDs.contains(request.taskID) else {
            return false
        }
        instructionInFlightTaskIDs.insert(request.taskID)
        instructionNoticeByTaskID[request.taskID] = nil
        instructionErrorByTaskID[request.taskID] = nil
        defer { instructionInFlightTaskIDs.remove(request.taskID) }

        do {
            let receipt = try await instructionSubmitter.submitTaskInstruction(request)
            let disposition = receipt.duplicate ? "already accepted" : "accepted"
            instructionNoticeByTaskID[request.taskID] =
                "Astra instruction \(disposition) · comment #\(receipt.sourceCommentID) · envelope \(receipt.envelopeTaskID)"
            _ = await performRefresh()
            return true
        } catch {
            instructionErrorByTaskID[request.taskID] = error.localizedDescription
            return false
        }
    }

    private func recordArchiveFailure(_ error: Error, for requestedTask: CorrelatedTask) {
        if let workflowError = error as? RemoteArchiveWorkflowError {
            switch workflowError {
            case .refreshFailedAfterArchive, .taskNoLongerDone:
                archiveFailure = TaskArchiveFailure(
                    task: requestedTask,
                    message: workflowError.localizedDescription,
                    canRetry: false
                )
            case .alreadyInProgress:
                break
            }
        } else if Self.isArchiveOutcomeUnknown(error) {
            let diagnostic = error.localizedDescription
            archiveFailure = TaskArchiveFailure(
                task: requestedTask,
                message: diagnostic.localizedCaseInsensitiveContains("outcome is unknown")
                    ? diagnostic
                    : "The remote archive outcome is unknown. Refresh the board before deciding whether to remove the task manually.",
                canRetry: false
            )
        } else if isArchiveStatusConflict(error) {
            archiveFailure = TaskArchiveFailure(
                task: requestedTask,
                message: "Task is no longer Done; it was not removed. Refresh to review its current status.",
                canRetry: false
            )
        } else {
            archiveFailure = TaskArchiveFailure(
                task: requestedTask,
                message: "Couldn’t remove “\(requestedTask.task.title)”. " +
                    "No task record was deleted. \(error.localizedDescription)",
                canRetry: true
            )
        }
    }

    private static func isArchiveOutcomeUnknown(_ error: Error) -> Bool {
        if let transportError = error as? OpenSSHTransportError,
           case .archiveProcessTimedOut = transportError {
            return true
        }
        return error is CancellationError
    }

    func retryArchive() async {
        guard let failure = archiveFailure, failure.canRetry else { return }
        archiveFailure = nil
        await archiveDoneTask(failure.task)
    }

    func dismissArchiveFeedback() {
        archiveFailure = nil
        archiveNotice = nil
    }

    func link(taskID: String, to sessionID: String) {
        let previous = manualSessionLinks[taskID]
        manualSessionLinks[taskID] = sessionID

        do {
            try manualLinkStore.save(manualSessionLinks)
            if let snapshot {
                self.snapshot = applyingManualLinks(to: snapshot)
            }
        } catch {
            manualSessionLinks[taskID] = previous
            errorMessage = "Could not save manual link: \(error.localizedDescription)"
        }
    }

    func reportNonfatalError(_ error: Error) {
        persistentErrorMessage = error.localizedDescription
        errorMessage = persistentErrorMessage
    }

    func selectTask(_ taskID: String) {
        selectedTaskID = taskID
    }

    private func apply(_ refreshedSnapshot: HermesMonitorSnapshot) {
        let presentedSnapshot = applyingManualLinks(to: refreshedSnapshot)
        snapshot = presentedSnapshot
        lastUpdate = refreshedSnapshot.refreshedAt
        connectionState = .connected
        errorMessage = persistentErrorMessage
        onSnapshot?(presentedSnapshot)
    }

    private func isArchiveStatusConflict(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("not done") ||
            message.contains("only done") ||
            message.contains("must be done") ||
            (message.contains("task") && message.contains("not found"))
    }

    private func applyingManualLinks(
        to snapshot: HermesMonitorSnapshot
    ) -> HermesMonitorSnapshot {
        let tasks = TaskCorrelator(manualSessionLinks: manualSessionLinks).correlate(
            tasks: snapshot.kanban.tasks,
            runs: snapshot.kanban.runs,
            sessions: snapshot.state.sessions
        )
        return HermesMonitorSnapshot(
            kanban: snapshot.kanban,
            state: snapshot.state,
            tasks: tasks,
            logTails: snapshot.logTails,
            warnings: snapshot.warnings,
            refreshedAt: snapshot.refreshedAt
        )
    }
}

enum MonitorConnectionState {
    case disconnected
    case connecting
    case connected
    case failed
}
