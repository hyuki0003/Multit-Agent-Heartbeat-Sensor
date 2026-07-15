import CSQLite
import Foundation
import XCTest
@testable import HermesMonitorCore

final class RemoteSnapshotSynchronizerTests: XCTestCase {
    func testAlwaysRefreshesSmallKanbanCopyAndDownloadsOtherFilesOnlyWhenChanged() async throws {
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
        _ = try await synchronizer.refresh(taskIDs: ["t_1"])
        let downloadsAfterSecondRefresh = await transport.downloadedPaths()
        let tailDownloadsAfterSecondRefresh = await transport.tailDownloadedPaths()
        XCTAssertEqual(downloadsAfterSecondRefresh, [
            RemotePathPolicy.kanbanDatabase,
            RemotePathPolicy.stateDatabase,
            logPath,
            RemotePathPolicy.kanbanDatabase
        ])
        XCTAssertEqual(tailDownloadsAfterSecondRefresh, [logPath])
        XCTAssertEqual(try Data(contentsOf: first.kanbanDatabase), databaseData)

        await transport.setMetadata(.init(
            path: RemotePathPolicy.stateDatabase,
            size: 4,
            modificationToken: "s2"
        ))
        await transport.setPayload(databaseData, for: RemotePathPolicy.stateDatabase)
        _ = try await synchronizer.refresh(taskIDs: ["t_1"])

        let downloadsAfterChange = await transport.downloadedPaths()
        XCTAssertEqual(Array(downloadsAfterChange.suffix(2)), [
            RemotePathPolicy.kanbanDatabase,
            RemotePathPolicy.stateDatabase
        ])
    }

    func testRejectsInvalidDatabaseBeforeReplacingCachedSnapshot() async throws {
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
        await transport.setMetadata(.init(
            path: RemotePathPolicy.kanbanDatabase,
            size: 12,
            modificationToken: "2026-07-15 12:00:01.000000000 +0900"
        ))
        await transport.setPayload(Data("not a sqlite".utf8), for: RemotePathPolicy.kanbanDatabase)

        do {
            _ = try await synchronizer.refresh(taskIDs: [])
            XCTFail("Expected invalid downloaded SQLite snapshot to be rejected")
        } catch SnapshotSynchronizerError.invalidDatabaseSnapshot(let path, _) {
            XCTAssertEqual(path, RemotePathPolicy.kanbanDatabase)
        }
        XCTAssertEqual(try Data(contentsOf: first.kanbanDatabase), databaseData)
    }

    func testTransientLogFailureKeepsLastSuccessfulTail() async throws {
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
        let synchronizer = RemoteSnapshotSynchronizer(
            transport: transport,
            localDirectory: localDirectory
        )
        let first = try await synchronizer.refresh(taskIDs: ["t_cache"])
        await transport.setMetadata(.init(path: logPath, size: 6, modificationToken: "l2"))
        await transport.setTailDownloadFailure(for: logPath)

        let second = try await synchronizer.refresh(taskIDs: ["t_cache"])

        XCTAssertEqual(second.workerLogs["t_cache"], first.workerLogs["t_cache"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(second.workerLogs["t_cache"])), Data("last\n".utf8))
        XCTAssertEqual(second.warnings.count, 1)
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
    private var tailDownloads: [String] = []
    private var failingTailDownloads: Set<String> = []

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

    func downloadTail(remotePath: String, to localURL: URL, byteLimit: Int) async throws {
        if failingTailDownloads.contains(remotePath) {
            throw CocoaError(.fileReadUnknown)
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

    func downloadedPaths() -> [String] { downloads }
    func tailDownloadedPaths() -> [String] { tailDownloads }
}
