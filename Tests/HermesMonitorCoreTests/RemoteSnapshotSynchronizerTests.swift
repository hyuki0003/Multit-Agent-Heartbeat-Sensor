import Foundation
import XCTest
@testable import HermesMonitorCore

final class RemoteSnapshotSynchronizerTests: XCTestCase {
    func testAlwaysRefreshesSmallKanbanCopyAndDownloadsOtherFilesOnlyWhenChanged() async throws {
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let logPath = try RemotePathPolicy().workerLogPath(taskID: "t_1")
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
                RemotePathPolicy.kanbanDatabase: Data("kan".utf8),
                RemotePathPolicy.stateDatabase: Data("sta".utf8),
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
        XCTAssertEqual(downloadsAfterSecondRefresh, [
            RemotePathPolicy.kanbanDatabase,
            RemotePathPolicy.stateDatabase,
            logPath,
            RemotePathPolicy.kanbanDatabase
        ])
        XCTAssertEqual(try String(contentsOf: first.kanbanDatabase, encoding: .utf8), "kan")

        await transport.setMetadata(.init(
            path: RemotePathPolicy.stateDatabase,
            size: 4,
            modificationToken: "s2"
        ))
        await transport.setPayload(Data("sta2".utf8), for: RemotePathPolicy.stateDatabase)
        _ = try await synchronizer.refresh(taskIDs: ["t_1"])

        let downloadsAfterChange = await transport.downloadedPaths()
        XCTAssertEqual(Array(downloadsAfterChange.suffix(2)), [
            RemotePathPolicy.kanbanDatabase,
            RemotePathPolicy.stateDatabase
        ])
    }
}

private actor FakeRemoteFileTransport: RemoteFileTransport {
    private var metadataValues: [String: RemoteFileMetadata]
    private var payloads: [String: Data]
    private var downloads: [String] = []

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

    func setMetadata(_ metadata: RemoteFileMetadata) {
        metadataValues[metadata.path] = metadata
    }

    func setPayload(_ data: Data, for path: String) {
        payloads[path] = data
    }

    func downloadedPaths() -> [String] { downloads }
}
