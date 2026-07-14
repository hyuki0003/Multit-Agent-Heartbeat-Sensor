import Foundation

public actor HermesMonitorClient {
    private let synchronizer: RemoteSnapshotSynchronizer
    private let loader: HermesSnapshotLoader
    private var knownTaskIDs: [String] = []

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
    }

    public func refresh() async throws -> HermesMonitorSnapshot {
        var files = try await synchronizer.refresh(taskIDs: knownTaskIDs)
        var snapshot = try loader.load(files: files)
        let currentTaskIDs = snapshot.kanban.tasks.map(\.id).sorted()

        if currentTaskIDs != knownTaskIDs {
            knownTaskIDs = currentTaskIDs
            files = try await synchronizer.refresh(taskIDs: currentTaskIDs)
            snapshot = try loader.load(files: files)
        }
        return snapshot
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
