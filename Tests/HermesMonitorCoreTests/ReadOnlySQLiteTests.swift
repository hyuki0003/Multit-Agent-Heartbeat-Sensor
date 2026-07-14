import CSQLite
import Foundation
import XCTest
@testable import HermesMonitorCore

final class ReadOnlySQLiteTests: XCTestCase {
    func testUsesReadOnlyURIAndLoadsVerifiedKanbanSchema() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanban-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        try createKanbanFixture(at: databaseURL)

        let uri = ReadOnlySQLiteDatabase.uri(for: databaseURL)
        XCTAssertTrue(uri.hasPrefix("file:"))
        XCTAssertTrue(uri.contains("mode=ro"))

        let database = try ReadOnlySQLiteDatabase(url: databaseURL)
        let snapshot = try KanbanStore(database: database).loadSnapshot()

        XCTAssertEqual(snapshot.tasks.count, 1)
        XCTAssertEqual(snapshot.tasks[0].id, "t_1")
        XCTAssertEqual(snapshot.tasks[0].status, .running)
        XCTAssertEqual(snapshot.runs[0].metadataPID, 123)
        XCTAssertEqual(snapshot.events[0].kind, "heartbeat")
        XCTAssertEqual(snapshot.comments[0].author, "astra")
        XCTAssertEqual(snapshot.links[0], TaskLink(parentID: "t_parent", childID: "t_1"))
    }

    func testReadOnlyConnectionRejectsWrites() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("readonly-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        try createKanbanFixture(at: databaseURL)

        let database = try ReadOnlySQLiteDatabase(url: databaseURL)
        XCTAssertThrowsError(try database.query("DELETE FROM tasks") { _ in 0 })
    }

    private func createKanbanFixture(at url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "fixture", code: 1)
        }
        defer { sqlite3_close(handle) }
        let sql = """
        CREATE TABLE tasks (
          id TEXT, title TEXT, body TEXT, assignee TEXT, status TEXT, priority INTEGER,
          created_at INTEGER, started_at INTEGER, completed_at INTEGER,
          workspace_kind TEXT, workspace_path TEXT, worker_pid INTEGER,
          last_heartbeat_at INTEGER, current_run_id INTEGER, session_id TEXT, result TEXT,
          consecutive_failures INTEGER, last_failure_error TEXT
        );
        CREATE TABLE task_runs (
          id INTEGER, task_id TEXT, profile TEXT, status TEXT, worker_pid INTEGER,
          last_heartbeat_at INTEGER, started_at INTEGER, ended_at INTEGER, outcome TEXT,
          summary TEXT, metadata TEXT, error TEXT
        );
        CREATE TABLE task_events (
          id INTEGER, task_id TEXT, run_id INTEGER, kind TEXT, payload TEXT, created_at INTEGER
        );
        CREATE TABLE task_comments (
          id INTEGER, task_id TEXT, author TEXT, body TEXT, created_at INTEGER
        );
        CREATE TABLE task_links (parent_id TEXT, child_id TEXT);
        INSERT INTO tasks VALUES (
          't_1', 'Test', 'Body', 'rune', 'running', 3, 100, 101, NULL,
          'dir', '/tmp/work', 123, 110, 7, 'session-1', NULL, 0, NULL
        );
        INSERT INTO task_runs VALUES (
          7, 't_1', 'rune', 'running', 123, 110, 101, NULL, NULL,
          NULL, '{"pid":123}', NULL
        );
        INSERT INTO task_events VALUES (1, 't_1', 7, 'heartbeat', '{}', 110);
        INSERT INTO task_comments VALUES (1, 't_1', 'astra', 'go', 100);
        INSERT INTO task_links VALUES ('t_parent', 't_1');
        """
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown fixture error"
            if let error { sqlite3_free(error) }
            throw NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
