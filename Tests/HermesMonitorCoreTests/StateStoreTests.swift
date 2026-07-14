import CSQLite
import Foundation
import XCTest
@testable import HermesMonitorCore

final class StateStoreTests: XCTestCase {
    func testLoadsSessionsAndReturnsBoundedMessagesInChronologicalOrder() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("state-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        try createStateFixture(at: databaseURL)

        let database = try ReadOnlySQLiteDatabase(url: databaseURL)
        let store = StateStore(database: database)
        let sessions = try store.loadSessions()
        let messages = try store.messages(sessionID: "session-1", limit: 2)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].parentSessionID, "parent")
        XCTAssertEqual(messages.map(\.id), [2, 3])
        XCTAssertEqual(messages.map(\.content), ["second", "third"])
    }

    private func createStateFixture(at url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "fixture", code: 1)
        }
        defer { sqlite3_close(handle) }
        let sql = """
        CREATE TABLE sessions (
          id TEXT, source TEXT, user_id TEXT, model TEXT, parent_session_id TEXT,
          started_at INTEGER, ended_at INTEGER, end_reason TEXT, message_count INTEGER,
          tool_call_count INTEGER, cwd TEXT, title TEXT, handoff_state TEXT
        );
        CREATE TABLE messages (
          id INTEGER, session_id TEXT, role TEXT, content TEXT, tool_calls TEXT,
          tool_name TEXT, timestamp INTEGER, finish_reason TEXT
        );
        INSERT INTO sessions VALUES (
          'session-1', 'kanban', 'user', 'model', 'parent', 100, NULL, NULL,
          3, 0, '/tmp/work', 'Title', NULL
        );
        INSERT INTO messages VALUES (1, 'session-1', 'user', 'first', NULL, NULL, 101, NULL);
        INSERT INTO messages VALUES (2, 'session-1', 'assistant', 'second', NULL, NULL, 102, NULL);
        INSERT INTO messages VALUES (3, 'session-1', 'assistant', 'third', NULL, NULL, 103, 'stop');
        """
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown fixture error"
            if let error { sqlite3_free(error) }
            throw NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
