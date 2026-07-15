import CSQLite
import Foundation

public enum SQLiteStoreError: Error, LocalizedError {
    case openFailed(path: String, message: String)
    case connectionIsNotReadOnly
    case prepareFailed(sql: String, message: String)
    case bindFailed(message: String)
    case stepFailed(sql: String, message: String)
    case missingRequiredColumn(Int32)
    case invalidValue(column: Int32, value: String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let path, let message): return "Could not open \(path) read-only: \(message)"
        case .connectionIsNotReadOnly: return "SQLite did not confirm that the main database is read-only."
        case .prepareFailed(let sql, let message): return "Could not prepare SQL '\(sql)': \(message)"
        case .bindFailed(let message): return "Could not bind SQLite value: \(message)"
        case .stepFailed(let sql, let message): return "Could not execute SQL '\(sql)': \(message)"
        case .missingRequiredColumn(let column): return "Required SQLite column \(column) was NULL."
        case .invalidValue(let column, let value): return "Invalid value '\(value)' in SQLite column \(column)."
        }
    }
}

enum SQLiteBinding: Sendable {
    case text(String)
    case int64(Int64)
}

public final class ReadOnlySQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()

    public static func uri(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        return components?.string ?? "file:\(url.path)?mode=ro"
    }

    public init(url: URL) throws {
        let uri = Self.uri(for: url)
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(uri, &database, flags, nil)
        guard status == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            if let database { sqlite3_close_v2(database) }
            throw SQLiteStoreError.openFailed(path: uri, message: message)
        }
        guard sqlite3_db_readonly(database, "main") == 1 else {
            sqlite3_close_v2(database)
            throw SQLiteStoreError.connectionIsNotReadOnly
        }
        sqlite3_busy_timeout(database, 1_000)
        self.handle = database
    }

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }

    public func quickCheck() throws -> [String] {
        try query("PRAGMA quick_check") { row in
            try row.requiredString(0)
        }
    }

    func query<T>(
        _ sql: String,
        bindings: [SQLiteBinding] = [],
        map: (SQLiteRow) throws -> T
    ) throws -> [T] {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else {
            throw SQLiteStoreError.openFailed(path: "closed", message: "database connection is closed")
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteStoreError.prepareFailed(sql: sql, message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement, handle: handle)

        var values: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW {
                values.append(try map(SQLiteRow(statement: statement)))
            } else if status == SQLITE_DONE {
                return values
            } else {
                throw SQLiteStoreError.stepFailed(sql: sql, message: String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    private func bind(
        _ bindings: [SQLiteBinding],
        to statement: OpaquePointer,
        handle: OpaquePointer
    ) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch binding {
            case .text(let value):
                status = value.withCString { pointer in
                    sqlite3_bind_text(statement, index, pointer, -1, transient)
                }
            case .int64(let value):
                status = sqlite3_bind_int64(statement, index, value)
            }
            guard status == SQLITE_OK else {
                throw SQLiteStoreError.bindFailed(message: String(cString: sqlite3_errmsg(handle)))
            }
        }
    }
}

struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func optionalString(_ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: text)
    }

    func requiredString(_ column: Int32) throws -> String {
        guard let value = optionalString(column) else {
            throw SQLiteStoreError.missingRequiredColumn(column)
        }
        return value
    }

    func optionalInt64(_ column: Int32) -> Int64? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, column)
    }

    func requiredInt64(_ column: Int32) throws -> Int64 {
        guard let value = optionalInt64(column) else {
            throw SQLiteStoreError.missingRequiredColumn(column)
        }
        return value
    }

    func optionalDate(_ column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let value = sqlite3_column_double(statement, column)
        return Date(timeIntervalSince1970: value)
    }

    func requiredDate(_ column: Int32) throws -> Date {
        guard let value = optionalDate(column) else {
            throw SQLiteStoreError.missingRequiredColumn(column)
        }
        return value
    }
}
