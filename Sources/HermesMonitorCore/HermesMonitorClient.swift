import Foundation

public struct MonitorRefreshBackoff: Equatable, Sendable {
    private let baseDelay: TimeInterval
    private let maximumDelay: TimeInterval

    public init(baseDelay: TimeInterval, maximumDelay: TimeInterval = 300) {
        self.baseDelay = max(0, baseDelay)
        self.maximumDelay = max(self.baseDelay, maximumDelay)
    }

    public func delay(afterConsecutiveFailures failures: Int) -> TimeInterval {
        let exponent = min(max(0, failures), 30)
        return min(maximumDelay, baseDelay * pow(2, Double(exponent)))
    }

    public func delay(
        afterConsecutiveFailures failures: Int,
        elapsed: TimeInterval
    ) -> TimeInterval {
        let scheduledDelay = delay(afterConsecutiveFailures: failures)
        guard failures <= 0 else { return scheduledDelay }
        return max(0, scheduledDelay - max(0, elapsed))
    }
}

public actor HermesMonitorClient: HermesMonitorServing {
    private let synchronizer: RemoteSnapshotSynchronizer
    private let loader: HermesSnapshotLoader
    private let archiver: any RemoteKanbanArchiving
    private var knownWorkerLogTaskIDs: [String] = []

    public init(
        configuration: SSHConnectionConfiguration,
        cacheDirectory: URL,
        credentials: any SSHCredentialProviding = KeychainSSHCredentialStore(),
        correlator: TaskCorrelator = TaskCorrelator()
    ) {
        let transport = OpenSSHTransport(
            configuration: configuration,
            credentials: credentials
        )
        self.synchronizer = RemoteSnapshotSynchronizer(
            transport: transport,
            localDirectory: cacheDirectory
        )
        self.loader = HermesSnapshotLoader(correlator: correlator)
        self.archiver = transport
    }

    public func refresh() async throws -> HermesMonitorSnapshot {
        var files = try await synchronizer.refresh(taskIDs: knownWorkerLogTaskIDs)
        var snapshot = try loader.load(files: files)
        let currentTaskIDs = Self.workerLogTaskIDs(for: snapshot.kanban.tasks)

        if currentTaskIDs != knownWorkerLogTaskIDs {
            knownWorkerLogTaskIDs = currentTaskIDs
            files = try await synchronizer.refresh(taskIDs: currentTaskIDs)
            snapshot = try loader.load(files: files)
        }
        return snapshot
    }

    public func archiveDoneTask(taskID: String) async throws {
        try await archiver.archiveDoneTask(taskID: taskID)
    }

    public func authoritativeTaskStatus(taskID: String) async throws -> KanbanTaskStatus? {
        let snapshot = try await refresh()
        return snapshot.kanban.tasks.first(where: { $0.id == taskID })?.status
    }

    static func workerLogTaskIDs(for tasks: [KanbanTask]) -> [String] {
        tasks
            .filter { $0.status == .running }
            .map(\.id)
            .sorted()
    }

    public nonisolated func snapshots(
        every interval: Duration = .seconds(10)
    ) -> AsyncThrowingStream<HermesMonitorSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    while !Task.isCancelled {
                        continuation.yield(try await self.refresh())
                        try await Task.sleep(for: interval)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public static func defaultCacheDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("HermesMonitor/RemoteSnapshots", isDirectory: true)
    }
}
