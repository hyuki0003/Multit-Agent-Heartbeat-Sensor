import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct RemoteSnapshotFiles: Equatable, Sendable {
    public let kanbanDatabase: URL
    public let stateDatabase: URL
    public let workerLogs: [String: URL]
    public let warnings: [String]
    public let refreshedAt: Date

    public init(
        kanbanDatabase: URL,
        stateDatabase: URL,
        workerLogs: [String: URL],
        warnings: [String],
        refreshedAt: Date
    ) {
        self.kanbanDatabase = kanbanDatabase
        self.stateDatabase = stateDatabase
        self.workerLogs = workerLogs
        self.warnings = warnings
        self.refreshedAt = refreshedAt
    }
}

public enum SnapshotSynchronizerError: Error, LocalizedError {
    case remoteFileChangedRepeatedly(String)
    case invalidDatabaseSnapshot(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .remoteFileChangedRepeatedly(let path):
            return "Remote file changed during two consecutive SFTP downloads: \(path)"
        case .invalidDatabaseSnapshot(let path, let reason):
            return "Downloaded SQLite snapshot failed validation for \(path): \(reason)"
        }
    }
}

public actor RemoteSnapshotSynchronizer {
    private static let workerLogByteLimit = 64 * 1_024

    private let transport: any RemoteFileTransport
    private let localDirectory: URL
    private let pathPolicy: RemotePathPolicy
    private let fileManager: FileManager
    private var synchronizedMetadata: [String: RemoteFileMetadata] = [:]

    public init(
        transport: any RemoteFileTransport,
        localDirectory: URL,
        pathPolicy: RemotePathPolicy = RemotePathPolicy(),
        fileManager: FileManager = .default
    ) {
        self.transport = transport
        self.localDirectory = localDirectory
        self.pathPolicy = pathPolicy
        self.fileManager = fileManager
    }

    public func refresh(taskIDs: [String]) async throws -> RemoteSnapshotFiles {
        try fileManager.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        let databaseDirectory = localDirectory.appendingPathComponent("databases", isDirectory: true)
        let logsDirectory = localDirectory.appendingPathComponent("logs", isDirectory: true)
        try fileManager.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        let kanbanURL = databaseDirectory.appendingPathComponent("kanban.db")
        let stateURL = databaseDirectory.appendingPathComponent("state.db")
        try await synchronizeDatabase(
            remotePath: RemotePathPolicy.kanbanDatabase,
            destination: kanbanURL
        )
        try await synchronizeDatabase(
            remotePath: RemotePathPolicy.stateDatabase,
            destination: stateURL
        )
        var logFiles: [String: URL] = [:]
        var warnings: [String] = []
        for taskID in Set(taskIDs).sorted() {
            do {
                let remotePath = try pathPolicy.workerLogPath(taskID: taskID)
                let destination = logsDirectory.appendingPathComponent("\(taskID).log")
                do {
                    try await synchronize(
                        remotePath: remotePath,
                        destination: destination,
                        tailByteLimit: Self.workerLogByteLimit
                    )
                    logFiles[taskID] = destination
                } catch {
                    warnings.append("Could not refresh log for \(taskID): \(error.localizedDescription)")
                    if fileManager.fileExists(atPath: destination.path) {
                        logFiles[taskID] = destination
                    }
                }
            } catch {
                warnings.append("Rejected log path for \(taskID): \(error.localizedDescription)")
            }
        }

        return RemoteSnapshotFiles(
            kanbanDatabase: kanbanURL,
            stateDatabase: stateURL,
            workerLogs: logFiles,
            warnings: warnings,
            refreshedAt: Date()
        )
    }

    public nonisolated func poll(
        every interval: Duration = .seconds(10),
        taskIDs: @escaping @Sendable () async -> [String]
    ) -> AsyncThrowingStream<RemoteSnapshotFiles, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    while !Task.isCancelled {
                        let files = try await self.refresh(taskIDs: await taskIDs())
                        continuation.yield(files)
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

    private func synchronizeDatabase(remotePath: String, destination: URL) async throws {
        _ = try pathPolicy.validateDatabasePath(remotePath)
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        defer { removeSQLiteFamily(at: partial) }

        try await transport.downloadDatabaseSnapshot(remotePath: remotePath, to: partial)
        try validateDatabaseSnapshot(at: partial, remotePath: remotePath)
        try removeSQLiteSidecars(at: destination)
        try install(partial: partial, destination: destination)
    }

    private func synchronize(
        remotePath: String,
        destination: URL,
        tailByteLimit: Int? = nil
    ) async throws {
        var before = try await transport.metadata(for: remotePath)
        if synchronizedMetadata[remotePath] == before,
           fileManager.fileExists(atPath: destination.path) {
            return
        }

        for _ in 0..<2 {
            let partial = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
            defer { try? fileManager.removeItem(at: partial) }
            if let tailByteLimit {
                try await transport.downloadTail(
                    remotePath: remotePath,
                    to: partial,
                    byteLimit: tailByteLimit
                )
            } else {
                try await transport.download(remotePath: remotePath, to: partial)
            }
            let after = try await transport.metadata(for: remotePath)
            guard before == after else {
                before = after
                continue
            }

            try install(partial: partial, destination: destination)
            synchronizedMetadata[remotePath] = after
            return
        }
        throw SnapshotSynchronizerError.remoteFileChangedRepeatedly(remotePath)
    }

    private func validateDatabaseSnapshot(at url: URL, remotePath: String) throws {
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let header = try file.read(upToCount: 16) ?? Data()
            guard header == Data("SQLite format 3\0".utf8) else {
                throw SnapshotSynchronizerError.invalidDatabaseSnapshot(
                    path: remotePath,
                    reason: "missing SQLite format 3 header"
                )
            }
            let database = try ReadOnlySQLiteDatabase(url: url)
            let results = try database.quickCheck()
            guard results == ["ok"] else {
                throw SnapshotSynchronizerError.invalidDatabaseSnapshot(
                    path: remotePath,
                    reason: results.joined(separator: "; ")
                )
            }
            let journalMode = try database.journalMode()
            guard journalMode == "delete" else {
                throw SnapshotSynchronizerError.invalidDatabaseSnapshot(
                    path: remotePath,
                    reason: "journal_mode was \(journalMode), expected delete"
                )
            }
        } catch let error as SnapshotSynchronizerError {
            throw error
        } catch {
            throw SnapshotSynchronizerError.invalidDatabaseSnapshot(
                path: remotePath,
                reason: error.localizedDescription
            )
        }
    }

    private func removeSQLiteFamily(at url: URL) {
        try? fileManager.removeItem(at: url)
        try? removeSQLiteSidecars(at: url)
    }

    private func removeSQLiteSidecars(at url: URL) throws {
        for suffix in ["-journal", "-wal", "-shm"] {
            let path = url.path + suffix
            if fileManager.fileExists(atPath: path) {
                try fileManager.removeItem(atPath: path)
            }
        }
    }

    private func install(partial: URL, destination: URL) throws {
        let status = partial.path.withCString { source in
            destination.path.withCString { target in
                atomicRename(source, target)
            }
        }
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private func atomicRename(_ source: UnsafePointer<CChar>, _ target: UnsafePointer<CChar>) -> Int32 {
    #if canImport(Darwin)
    Darwin.rename(source, target)
    #elseif canImport(Glibc)
    Glibc.rename(source, target)
    #endif
}

public struct HermesMonitorSnapshot: Equatable, Sendable {
    public let kanban: KanbanSnapshot
    public let state: StateSnapshot
    public let tasks: [CorrelatedTask]
    public let logTails: [String: [String]]
    public let warnings: [String]
    public let refreshedAt: Date

    public init(
        kanban: KanbanSnapshot,
        state: StateSnapshot,
        tasks: [CorrelatedTask],
        logTails: [String: [String]],
        warnings: [String],
        refreshedAt: Date
    ) {
        self.kanban = kanban
        self.state = state
        self.tasks = tasks
        self.logTails = logTails
        self.warnings = warnings
        self.refreshedAt = refreshedAt
    }
}

public struct HermesSnapshotLoader: Sendable {
    private let correlator: TaskCorrelator

    public init(correlator: TaskCorrelator = TaskCorrelator()) {
        self.correlator = correlator
    }

    public func load(files: RemoteSnapshotFiles, logLineLimit: Int = 200) throws -> HermesMonitorSnapshot {
        let kanbanDatabase = try ReadOnlySQLiteDatabase(url: files.kanbanDatabase)
        let stateDatabase = try ReadOnlySQLiteDatabase(url: files.stateDatabase)
        let kanban = try KanbanStore(database: kanbanDatabase).loadSnapshot()
        let state = try StateStore(database: stateDatabase).loadSnapshot()
        let tasks = correlator.correlate(
            tasks: kanban.tasks,
            runs: kanban.runs,
            sessions: state.sessions
        )
        let tails = files.workerLogs.reduce(into: [String: [String]]()) { result, entry in
            guard let data = try? Data(contentsOf: entry.value, options: .mappedIfSafe) else { return }
            result[entry.key] = LogTailParser.lines(from: data, limit: logLineLimit)
        }
        return HermesMonitorSnapshot(
            kanban: kanban,
            state: state,
            tasks: tasks,
            logTails: tails,
            warnings: files.warnings,
            refreshedAt: files.refreshedAt
        )
    }
}
