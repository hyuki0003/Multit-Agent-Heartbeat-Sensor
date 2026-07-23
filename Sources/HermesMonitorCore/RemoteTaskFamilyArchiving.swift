import CoreFoundation
import Foundation

public struct RemoteTaskFamilyArchiveRequest: Encodable, Equatable, Sendable {
    public static let maximumFamilies = 4
    public static let maximumTasks = 32

    public let maxFamilies: Int
    public let maxTasks: Int
    public let clientSource: String

    public init() {
        self.maxFamilies = Self.maximumFamilies
        self.maxTasks = Self.maximumTasks
        self.clientSource = "hermes-monitor"
    }

    private enum CodingKeys: String, CodingKey {
        case maxFamilies = "max_families"
        case maxTasks = "max_tasks"
        case clientSource = "client_source"
    }
}

public enum RemoteTaskFamilyArchiveOutcome: String, Sendable {
    case archived
    case noop
    case rejected
}

public struct RemoteTaskFamilyArchiveReceipt: Equatable, Sendable {
    public let outcome: RemoteTaskFamilyArchiveOutcome
    public let archivedFamilyCount: Int
    public let archivedTaskCount: Int
    public let archivedTaskIDs: [String]
    public let deferredFamilyCount: Int
    public let bounded: Bool
    public let reason: String?

    public init(
        outcome: RemoteTaskFamilyArchiveOutcome,
        archivedFamilyCount: Int,
        archivedTaskCount: Int,
        archivedTaskIDs: [String],
        deferredFamilyCount: Int,
        bounded: Bool,
        reason: String?
    ) {
        self.outcome = outcome
        self.archivedFamilyCount = archivedFamilyCount
        self.archivedTaskCount = archivedTaskCount
        self.archivedTaskIDs = archivedTaskIDs
        self.deferredFamilyCount = deferredFamilyCount
        self.bounded = bounded
        self.reason = reason
    }
}

public enum TaskFamilyArchiveCodecError: Error, Equatable, LocalizedError {
    case invalidReceipt

    public var errorDescription: String? {
        "원격 가족 보관 결과를 확인할 수 없습니다. 다음 새로고침에서 다시 확인하세요."
    }
}

public enum TaskFamilyArchiveCodec {
    private static let receiptKeys: Set<String> = [
        "outcome",
        "archived_family_count",
        "archived_task_count",
        "archived_task_ids",
        "deferred_family_count",
        "bounded",
        "reason",
    ]
    private static let canonicalTaskIDPattern = "^t_[0-9a-f]{8}$"

    public static func encode(_ request: RemoteTaskFamilyArchiveRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(request)
    }

    public static func decodeReceipt(_ data: Data) throws -> RemoteTaskFamilyArchiveReceipt {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == receiptKeys,
              let outcomeValue = object["outcome"] as? String,
              let outcome = RemoteTaskFamilyArchiveOutcome(rawValue: outcomeValue),
              let archivedFamilyCount = strictNonnegativeInteger(object["archived_family_count"]),
              let archivedTaskCount = strictNonnegativeInteger(object["archived_task_count"]),
              let archivedTaskIDs = object["archived_task_ids"] as? [String],
              let deferredFamilyCount = strictNonnegativeInteger(object["deferred_family_count"]),
              let bounded = strictBoolean(object["bounded"]),
              object.keys.contains("reason") else {
            throw TaskFamilyArchiveCodecError.invalidReceipt
        }
        let reason: String?
        if object["reason"] is NSNull {
            reason = nil
        } else if let value = object["reason"] as? String {
            reason = value
        } else {
            throw TaskFamilyArchiveCodecError.invalidReceipt
        }
        guard archivedTaskCount == archivedTaskIDs.count,
              Set(archivedTaskIDs).count == archivedTaskIDs.count,
              archivedFamilyCount <= archivedTaskCount,
              archivedFamilyCount <= RemoteTaskFamilyArchiveRequest.maximumFamilies,
              archivedTaskCount <= RemoteTaskFamilyArchiveRequest.maximumTasks,
              archivedTaskIDs.allSatisfy({ taskID in
                  taskID.range(of: canonicalTaskIDPattern, options: .regularExpression)
                      == taskID.startIndex..<taskID.endIndex
              }),
              isConsistent(
                  outcome: outcome,
                  archivedFamilyCount: archivedFamilyCount,
                  archivedTaskCount: archivedTaskCount,
                  bounded: bounded,
                  reason: reason
              ) else {
            throw TaskFamilyArchiveCodecError.invalidReceipt
        }
        return RemoteTaskFamilyArchiveReceipt(
            outcome: outcome,
            archivedFamilyCount: archivedFamilyCount,
            archivedTaskCount: archivedTaskCount,
            archivedTaskIDs: archivedTaskIDs,
            deferredFamilyCount: deferredFamilyCount,
            bounded: bounded,
            reason: reason
        )
    }

    private static func isConsistent(
        outcome: RemoteTaskFamilyArchiveOutcome,
        archivedFamilyCount: Int,
        archivedTaskCount: Int,
        bounded: Bool,
        reason: String?
    ) -> Bool {
        switch outcome {
        case .archived:
            return archivedFamilyCount > 0 && archivedTaskCount > 0 && reason == nil
        case .noop:
            return archivedFamilyCount == 0 && archivedTaskCount == 0 && reason == nil
        case .rejected:
            return archivedFamilyCount == 0
                && archivedTaskCount == 0
                && !bounded
                && reason == "malformed_graph"
        }
    }

    private static func strictBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    private static func strictNonnegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let integer = number.intValue
        guard integer >= 0, NSNumber(value: integer) == number else { return nil }
        return integer
    }
}

public protocol RemoteTaskFamilyArchiving: Sendable {
    func archiveCompletedTaskFamilies(
        _ request: RemoteTaskFamilyArchiveRequest
    ) async throws -> RemoteTaskFamilyArchiveReceipt
}

public protocol RemoteSnapshotRefreshing: Sendable {
    func refresh() async throws -> HermesMonitorSnapshot
}

public struct RemoteTaskFamilyArchiveMaintenanceResult: Sendable {
    public let receipt: RemoteTaskFamilyArchiveReceipt
    public let refreshedSnapshot: HermesMonitorSnapshot?

    public init(
        receipt: RemoteTaskFamilyArchiveReceipt,
        refreshedSnapshot: HermesMonitorSnapshot?
    ) {
        self.receipt = receipt
        self.refreshedSnapshot = refreshedSnapshot
    }
}

public enum RemoteTaskFamilyArchiveWorkflowError: Error, Equatable, LocalizedError {
    case alreadyInProgress
    case preflightRejected
    case refreshFailedAfterArchive

    public var errorDescription: String? {
        switch self {
        case .alreadyInProgress:
            return "완료 작업 보관을 이미 확인하고 있습니다."
        case .preflightRejected:
            return "작업 연결 구조를 안전하게 확인할 수 없어 이번 보관을 건너뛰었습니다."
        case .refreshFailedAfterArchive:
            return "완료 작업 보관 후 새로고침에 실패했습니다. 다음 새로고침에서 상태를 확인하세요."
        }
    }
}

public actor RemoteTaskFamilyArchiveWorkflow {
    private let archiver: any RemoteTaskFamilyArchiving
    private let refresher: any RemoteSnapshotRefreshing
    private var inFlight = false

    public init(
        archiver: any RemoteTaskFamilyArchiving,
        refresher: any RemoteSnapshotRefreshing
    ) {
        self.archiver = archiver
        self.refresher = refresher
    }

    public func performMaintenance() async throws -> RemoteTaskFamilyArchiveMaintenanceResult {
        guard !inFlight else {
            throw RemoteTaskFamilyArchiveWorkflowError.alreadyInProgress
        }
        inFlight = true
        defer { inFlight = false }

        let receipt = try await archiver.archiveCompletedTaskFamilies(
            RemoteTaskFamilyArchiveRequest()
        )
        switch receipt.outcome {
        case .noop:
            return RemoteTaskFamilyArchiveMaintenanceResult(
                receipt: receipt,
                refreshedSnapshot: nil
            )
        case .rejected:
            throw RemoteTaskFamilyArchiveWorkflowError.preflightRejected
        case .archived:
            do {
                return RemoteTaskFamilyArchiveMaintenanceResult(
                    receipt: receipt,
                    refreshedSnapshot: try await refresher.refresh()
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw RemoteTaskFamilyArchiveWorkflowError.refreshFailedAfterArchive
            }
        }
    }
}

public enum HermesTaskFamilyArchiveCommand {
    private static let fixedPrefix =
        "/usr/bin/env HERMES_KANBAN_BOARD=default " +
        "HERMES_KANBAN_DB=/home/dhlee/.hermes/kanban.db " +
        "PYTHONPATH=/home/dhlee/.hermes/hermes-agent " +
        "/home/dhlee/.hermes/hermes-agent/venv/bin/python -c "

    public static func remoteCommand(helper: String) -> String {
        fixedPrefix + shellQuoted(helper)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

enum TaskFamilyArchiveHelperResource {
    static var bundle: Bundle {
#if SWIFT_PACKAGE
        return Bundle.module
#else
        return Bundle.main
#endif
    }

    static var url: URL? {
        bundle.url(forResource: "TaskFamilyArchiveHelper", withExtension: "py")
    }
}
