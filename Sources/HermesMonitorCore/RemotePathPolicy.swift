import Foundation

public enum RemotePathPolicyError: Error, Equatable, LocalizedError {
    case databasePathNotAllowed(String)
    case invalidTaskID(String)

    public var errorDescription: String? {
        switch self {
        case .databasePathNotAllowed(let path):
            return "Remote database path is not allowed: \(path)"
        case .invalidTaskID(let taskID):
            return "Task ID cannot be converted to an approved log path: \(taskID)"
        }
    }
}

public struct RemotePathPolicy: Sendable {
    public static let kanbanDatabase = "/home/dhlee/.hermes/kanban.db"
    public static let stateDatabase = "/home/dhlee/.hermes/state.db"
    public static let workerLogsDirectory = "/home/dhlee/.hermes/kanban/logs"

    private static let allowedDatabasePaths: Set<String> = [
        kanbanDatabase,
        stateDatabase
    ]

    public init() {}

    @discardableResult
    public func validateDatabasePath(_ path: String) throws -> String {
        guard Self.allowedDatabasePaths.contains(path) else {
            throw RemotePathPolicyError.databasePathNotAllowed(path)
        }
        return path
    }

    public func workerLogPath(taskID: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard !taskID.isEmpty,
              taskID.unicodeScalars.allSatisfy(allowed.contains),
              !taskID.contains("..") else {
            throw RemotePathPolicyError.invalidTaskID(taskID)
        }
        return "\(Self.workerLogsDirectory)/\(taskID).log"
    }
}
