import Combine
import Foundation

@MainActor
final class MonitorViewModel: ObservableObject {
    @Published private(set) var snapshot: HermesMonitorSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var connectionState: MonitorConnectionState
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var selectedTaskID: String?

    private let client: HermesMonitorClient?
    private let manualLinkStore: ManualSessionLinkStore
    private var manualSessionLinks: [String: String]
    private var monitoringTask: Task<Void, Never>?
    private var persistentErrorMessage: String?
    var onSnapshot: ((HermesMonitorSnapshot) -> Void)?

    init(
        client: HermesMonitorClient?,
        initialError: String? = nil,
        manualLinkStore: ManualSessionLinkStore = ManualSessionLinkStore(
            fileURL: ManualSessionLinkStore.defaultFileURL()
        )
    ) {
        self.client = client
        self.manualLinkStore = manualLinkStore
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
            let presentedSnapshot = applyingManualLinks(to: refreshedSnapshot)
            snapshot = presentedSnapshot
            lastUpdate = refreshedSnapshot.refreshedAt
            connectionState = .connected
            errorMessage = persistentErrorMessage
            onSnapshot?(presentedSnapshot)
            return true
        } catch {
            connectionState = .failed
            errorMessage = error.localizedDescription
            return false
        }
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
