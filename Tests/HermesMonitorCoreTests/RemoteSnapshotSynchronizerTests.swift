import CSQLite
import Foundation
import XCTest
@testable import HermesMonitorCore

final class RemoteSnapshotSynchronizerTests: XCTestCase {
    func testRefreshesBothDatabaseSnapshotsEveryTimeAndDownloadsLogsOnlyWhenChanged() async throws {
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let logPath = try RemotePathPolicy().workerLogPath(taskID: "t_1")
        let databaseData = try sqliteDatabaseData()
        let transport = FakeRemoteFileTransport(
            metadata: [
                RemotePathPolicy.kanbanDatabase: .init(
                    path: RemotePathPolicy.kanbanDatabase,
                    size: 3,
                    modificationToken: "k1"
                ),
                RemotePathPolicy.stateDatabase: .init(
                    path: RemotePathPolicy.stateDatabase,
                    size: 3,
                    modificationToken: "s1"
                ),
                logPath: .init(path: logPath, size: 4, modificationToken: "l1")
            ],
            payloads: [
                RemotePathPolicy.kanbanDatabase: databaseData,
                RemotePathPolicy.stateDatabase: databaseData,
                logPath: Data("log\n".utf8)
            ]
        )
        let synchronizer = RemoteSnapshotSynchronizer(
            transport: transport,
            localDirectory: localDirectory
        )

        let first = try await synchronizer.refresh(taskIDs: ["t_1"])
        let staleWAL = URL(fileURLWithPath: first.kanbanDatabase.path + "-wal")
        let staleSHM = URL(fileURLWithPath: first.kanbanDatabase.path + "-shm")
        try Data("stale".utf8).write(to: staleWAL)
        try Data("stale".utf8).write(to: staleSHM)
        _ = try await synchronizer.refresh(taskIDs: ["t_1"])
        let downloadsAfterSecondRefresh = await transport.downloadedPaths()
        let snapshotsAfterSecondRefresh = await transport.snapshotDownloadedPaths()
        let tailDownloadsAfterSecondRefresh = await transport.tailDownloadedPaths()
        XCTAssertEqual(downloadsAfterSecondRefresh, [logPath])
        XCTAssertEqual(snapshotsAfterSecondRefresh, [
            RemotePathPolicy.kanbanDatabase,
            RemotePathPolicy.stateDatabase,
            RemotePathPolicy.kanbanDatabase,
            RemotePathPolicy.stateDatabase
        ])
        XCTAssertEqual(tailDownloadsAfterSecondRefresh, [logPath])
        XCTAssertEqual(try Data(contentsOf: first.kanbanDatabase), databaseData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleWAL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleSHM.path))

        await transport.setMetadata(.init(
            path: RemotePathPolicy.stateDatabase,
            size: 4,
            modificationToken: "s2"
        ))
        await transport.setPayload(databaseData, for: RemotePathPolicy.stateDatabase)
        _ = try await synchronizer.refresh(taskIDs: ["t_1"])

        let snapshotsAfterChange = await transport.snapshotDownloadedPaths()
        XCTAssertEqual(Array(snapshotsAfterChange.suffix(2)), [
            RemotePathPolicy.kanbanDatabase,
            RemotePathPolicy.stateDatabase
        ])
    }

    func testRejectsTruncatedAndCorruptDatabasesBeforeReplacingCachedSnapshot() async throws {
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let databaseData = try sqliteDatabaseData()
        let transport = FakeRemoteFileTransport(
            metadata: [
                RemotePathPolicy.kanbanDatabase: .init(
                    path: RemotePathPolicy.kanbanDatabase,
                    size: Int64(databaseData.count),
                    modificationToken: "2026-07-15 12:00:00.000000000 +0900"
                ),
                RemotePathPolicy.stateDatabase: .init(
                    path: RemotePathPolicy.stateDatabase,
                    size: Int64(databaseData.count),
                    modificationToken: "2026-07-15 12:00:00.000000000 +0900"
                )
            ],
            payloads: [
                RemotePathPolicy.kanbanDatabase: databaseData,
                RemotePathPolicy.stateDatabase: databaseData
            ]
        )
        let synchronizer = RemoteSnapshotSynchronizer(
            transport: transport,
            localDirectory: localDirectory
        )

        let first = try await synchronizer.refresh(taskIDs: [])
        let invalidPayloads = [
            Data(databaseData.prefix(32)),
            Data("not a sqlite".utf8)
        ]
        for (offset, payload) in invalidPayloads.enumerated() {
            await transport.setPayload(payload, for: RemotePathPolicy.kanbanDatabase)
            do {
                _ = try await synchronizer.refresh(taskIDs: [])
                XCTFail("Expected invalid downloaded SQLite snapshot to be rejected")
            } catch SnapshotSynchronizerError.invalidDatabaseSnapshot(let path, _) {
                XCTAssertEqual(path, RemotePathPolicy.kanbanDatabase)
            }
            XCTAssertEqual(try Data(contentsOf: first.kanbanDatabase), databaseData)
            let databaseDirectory = localDirectory.appendingPathComponent("databases", isDirectory: true)
            let leftovers = try FileManager.default.contentsOfDirectory(
                at: databaseDirectory,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.contains(".partial") }
            XCTAssertEqual(leftovers, [], "invalid payload \(offset) left partial artifacts")
        }
    }

    func testSnapshotHelperFailureKeepsLastValidatedDatabase() async throws {
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-helper-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let databaseData = try sqliteDatabaseData()
        let transport = FakeRemoteFileTransport(
            metadata: [:],
            payloads: [
                RemotePathPolicy.kanbanDatabase: databaseData,
                RemotePathPolicy.stateDatabase: databaseData
            ]
        )
        let synchronizer = RemoteSnapshotSynchronizer(
            transport: transport,
            localDirectory: localDirectory
        )
        let first = try await synchronizer.refresh(taskIDs: [])
        await transport.setSnapshotDownloadFailure(for: RemotePathPolicy.kanbanDatabase)

        do {
            _ = try await synchronizer.refresh(taskIDs: [])
            XCTFail("Expected the remote snapshot helper failure to be surfaced")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .fileReadUnknown)
        }
        XCTAssertEqual(try Data(contentsOf: first.kanbanDatabase), databaseData)
    }

    func testTransientLogFailureKeepsLastSuccessfulTailWithoutGlobalWarningSpam() async throws {
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-log-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let logPath = try RemotePathPolicy().workerLogPath(taskID: "t_cache")
        let databaseData = try sqliteDatabaseData()
        let transport = FakeRemoteFileTransport(
            metadata: [
                RemotePathPolicy.kanbanDatabase: .init(
                    path: RemotePathPolicy.kanbanDatabase,
                    size: Int64(databaseData.count),
                    modificationToken: "k1"
                ),
                RemotePathPolicy.stateDatabase: .init(
                    path: RemotePathPolicy.stateDatabase,
                    size: Int64(databaseData.count),
                    modificationToken: "s1"
                ),
                logPath: .init(path: logPath, size: 5, modificationToken: "l1")
            ],
            payloads: [
                RemotePathPolicy.kanbanDatabase: databaseData,
                RemotePathPolicy.stateDatabase: databaseData,
                logPath: Data("last\n".utf8)
            ]
        )
        let diagnostics = RecordingSnapshotDiagnosticSink()
        let synchronizer = RemoteSnapshotSynchronizer(
            transport: transport,
            localDirectory: localDirectory,
            diagnostics: diagnostics
        )
        let first = try await synchronizer.refresh(taskIDs: ["t_cache"])
        await transport.setMetadata(.init(path: logPath, size: 6, modificationToken: "l2"))
        await transport.setTailDownloadFailure(for: logPath)

        let second = try await synchronizer.refresh(taskIDs: ["t_cache"])
        let repeated = try await synchronizer.refresh(taskIDs: ["t_cache"])

        XCTAssertEqual(second.workerLogs["t_cache"], first.workerLogs["t_cache"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(second.workerLogs["t_cache"])), Data("last\n".utf8))
        XCTAssertTrue(second.warnings.isEmpty)
        XCTAssertTrue(repeated.warnings.isEmpty)
        let failureDiagnostics = await diagnostics.recorded()
        XCTAssertEqual(failureDiagnostics.map(\.kind), [.failed])

        try FileManager.default.removeItem(at: XCTUnwrap(second.workerLogs["t_cache"]))
        let withoutCache = try await synchronizer.refresh(taskIDs: ["t_cache"])
        XCTAssertNil(withoutCache.workerLogs["t_cache"])
        XCTAssertTrue(withoutCache.warnings.isEmpty)
        let noCacheDiagnostics = await diagnostics.recorded()
        XCTAssertEqual(noCacheDiagnostics.map(\.kind), [.failed])

        await transport.clearTailDownloadFailure(for: logPath)
        _ = try await synchronizer.refresh(taskIDs: ["t_cache"])
        let recoveredDiagnostics = await diagnostics.recorded()
        XCTAssertEqual(recoveredDiagnostics.map(\.kind), [.failed, .recovered])
    }

    func testLocalLogCacheFailureRemainsAnActionableGlobalWarning() async throws {
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-log-actionable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let logPath = try RemotePathPolicy().workerLogPath(taskID: "t_action")
        let databaseData = try sqliteDatabaseData()
        let transport = FakeRemoteFileTransport(
            metadata: [
                RemotePathPolicy.kanbanDatabase: .init(
                    path: RemotePathPolicy.kanbanDatabase,
                    size: Int64(databaseData.count),
                    modificationToken: "k1"
                ),
                RemotePathPolicy.stateDatabase: .init(
                    path: RemotePathPolicy.stateDatabase,
                    size: Int64(databaseData.count),
                    modificationToken: "s1"
                ),
                logPath: .init(path: logPath, size: 5, modificationToken: "l1")
            ],
            payloads: [
                RemotePathPolicy.kanbanDatabase: databaseData,
                RemotePathPolicy.stateDatabase: databaseData,
                logPath: Data("last\n".utf8)
            ]
        )
        let diagnostics = RecordingSnapshotDiagnosticSink()
        let synchronizer = RemoteSnapshotSynchronizer(
            transport: transport,
            localDirectory: localDirectory,
            diagnostics: diagnostics
        )
        let first = try await synchronizer.refresh(taskIDs: ["t_action"])
        await transport.setMetadata(.init(path: logPath, size: 6, modificationToken: "l2"))
        await transport.setActionableTailDownloadFailure(for: logPath)

        let second = try await synchronizer.refresh(taskIDs: ["t_action"])
        let recorded = await diagnostics.recorded()

        XCTAssertEqual(second.workerLogs["t_action"], first.workerLogs["t_action"])
        XCTAssertEqual(second.warnings.count, 1)
        XCTAssertTrue(second.warnings[0].contains("Could not refresh worker log"))
        XCTAssertTrue(recorded.isEmpty)
    }

    func testInvalidTaskIDCannotReuseFileOutsideLogCache() async throws {
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-log-traversal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let databaseData = try sqliteDatabaseData()
        let escapedLog = localDirectory.appendingPathComponent("escaped.log")
        try Data("must-not-be-loaded\n".utf8).write(to: escapedLog)
        let transport = FakeRemoteFileTransport(
            metadata: [
                RemotePathPolicy.kanbanDatabase: .init(
                    path: RemotePathPolicy.kanbanDatabase,
                    size: Int64(databaseData.count),
                    modificationToken: "k1"
                ),
                RemotePathPolicy.stateDatabase: .init(
                    path: RemotePathPolicy.stateDatabase,
                    size: Int64(databaseData.count),
                    modificationToken: "s1"
                )
            ],
            payloads: [
                RemotePathPolicy.kanbanDatabase: databaseData,
                RemotePathPolicy.stateDatabase: databaseData
            ]
        )
        let synchronizer = RemoteSnapshotSynchronizer(
            transport: transport,
            localDirectory: localDirectory
        )

        let files = try await synchronizer.refresh(taskIDs: ["../escaped"])

        XCTAssertNil(files.workerLogs["../escaped"])
        XCTAssertEqual(files.warnings.count, 1)
        XCTAssertEqual(try Data(contentsOf: escapedLog), Data("must-not-be-loaded\n".utf8))
    }

    private func sqliteDatabaseData() throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-fixture-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "fixture", code: 1)
        }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, "CREATE TABLE fixture (value TEXT);", nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "fixture", code: 2)
        }
        return try Data(contentsOf: url)
    }
}

private actor FakeRemoteFileTransport: RemoteFileTransport {
    private var metadataValues: [String: RemoteFileMetadata]
    private var payloads: [String: Data]
    private var downloads: [String] = []
    private var snapshotDownloads: [String] = []
    private var tailDownloads: [String] = []
    private var failingSnapshotDownloads: Set<String> = []
    private var failingTailDownloads: Set<String> = []
    private var actionableTailDownloads: Set<String> = []

    init(metadata: [String: RemoteFileMetadata], payloads: [String: Data]) {
        self.metadataValues = metadata
        self.payloads = payloads
    }

    func metadata(for remotePath: String) async throws -> RemoteFileMetadata {
        guard let value = metadataValues[remotePath] else {
            throw CocoaError(.fileNoSuchFile)
        }
        return value
    }

    func download(remotePath: String, to localURL: URL) async throws {
        guard let data = payloads[remotePath] else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: localURL)
        downloads.append(remotePath)
    }

    func downloadDatabaseSnapshot(remotePath: String, to localURL: URL) async throws {
        if failingSnapshotDownloads.contains(remotePath) {
            throw CocoaError(.fileReadUnknown)
        }
        guard let data = payloads[remotePath] else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: localURL)
        snapshotDownloads.append(remotePath)
    }

    func downloadTail(remotePath: String, to localURL: URL, byteLimit: Int) async throws {
        if actionableTailDownloads.contains(remotePath) {
            throw CocoaError(.fileWriteNoPermission)
        }
        if failingTailDownloads.contains(remotePath) {
            throw OpenSSHTransportError.processFailed(
                executable: "/usr/bin/sftp",
                status: 255,
                output: "Connection reset by peer"
            )
        }
        try await download(remotePath: remotePath, to: localURL)
        tailDownloads.append(remotePath)
    }

    func setMetadata(_ metadata: RemoteFileMetadata) {
        metadataValues[metadata.path] = metadata
    }

    func setPayload(_ data: Data, for path: String) {
        payloads[path] = data
    }

    func setTailDownloadFailure(for path: String) {
        failingTailDownloads.insert(path)
    }

    func clearTailDownloadFailure(for path: String) {
        failingTailDownloads.remove(path)
    }

    func setActionableTailDownloadFailure(for path: String) {
        actionableTailDownloads.insert(path)
    }

    func setSnapshotDownloadFailure(for path: String) {
        failingSnapshotDownloads.insert(path)
    }

    func downloadedPaths() -> [String] { downloads }
    func snapshotDownloadedPaths() -> [String] { snapshotDownloads }
    func tailDownloadedPaths() -> [String] { tailDownloads }
}

private actor RecordingSnapshotDiagnosticSink: RemoteSnapshotDiagnosticSink {
    private var diagnostics: [RemoteLogRefreshDiagnostic] = []

    func record(_ diagnostic: RemoteLogRefreshDiagnostic) async {
        diagnostics.append(diagnostic)
    }

    func recorded() -> [RemoteLogRefreshDiagnostic] { diagnostics }
}
