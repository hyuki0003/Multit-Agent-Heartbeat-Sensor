import CoreFoundation
import Foundation

public enum TaskInstructionValidationError: Error, Equatable, LocalizedError {
    case invalidTaskID(String)
    case emptyMessage
    case messageTooLarge(maximumBytes: Int)
    case invalidRunID(Int64)
    case invalidSelectedOptionID(String)
    case unavailableTaskBinding(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTaskID(let taskID):
            return "Refusing to submit an instruction for noncanonical Hermes task ID: \(taskID)"
        case .emptyMessage:
            return "Enter an instruction before sending."
        case .messageTooLarge(let maximumBytes):
            return "The instruction exceeds the \(maximumBytes)-byte UTF-8 limit."
        case .invalidRunID(let runID):
            return "Invalid Hermes run ID: \(runID)"
        case .invalidSelectedOptionID(let optionID):
            return "Invalid Clinical Report option ID: \(optionID)"
        case .unavailableTaskBinding(let taskID):
            return "Task \(taskID) does not have an authoritative instruction binding."
        }
    }
}

public struct RemoteTaskInstructionRequest: Encodable, Equatable, Sendable {
    public static let maximumMessageBytes = 4_000
    private static let canonicalTaskIDPattern = "^t_[0-9a-f]{8}$"

    public let instructionID: UUID
    public let taskID: String
    public let message: String
    public let runID: Int64?
    public let selectedOptionID: String?
    public let clientSource: String

    public init(
        taskID: String,
        message: String,
        instructionID: UUID = UUID(),
        runID: Int64? = nil,
        selectedOptionID: String? = nil
    ) throws {
        guard taskID.range(
            of: Self.canonicalTaskIDPattern,
            options: .regularExpression
        ) == taskID.startIndex..<taskID.endIndex else {
            throw TaskInstructionValidationError.invalidTaskID(taskID)
        }
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessage.isEmpty else {
            throw TaskInstructionValidationError.emptyMessage
        }
        guard normalizedMessage.utf8.count <= Self.maximumMessageBytes else {
            throw TaskInstructionValidationError.messageTooLarge(
                maximumBytes: Self.maximumMessageBytes
            )
        }
        if let runID, runID <= 0 {
            throw TaskInstructionValidationError.invalidRunID(runID)
        }
        if let selectedOptionID, !["A", "B", "C"].contains(selectedOptionID) {
            throw TaskInstructionValidationError.invalidSelectedOptionID(selectedOptionID)
        }

        self.instructionID = instructionID
        self.taskID = taskID
        self.message = normalizedMessage
        self.runID = runID
        self.selectedOptionID = selectedOptionID
        self.clientSource = "hermes-monitor"
    }

    public init(
        task: CorrelatedTask,
        message: String,
        instructionID: UUID = UUID(),
        selectedOptionID: String? = nil
    ) throws {
        let runID: Int64?
        switch task.instructionBinding {
        case .unbound:
            runID = nil
        case .run(let authoritativeRunID):
            runID = authoritativeRunID
        case .unavailable:
            throw TaskInstructionValidationError.unavailableTaskBinding(task.id)
        }
        try self.init(
            taskID: task.id,
            message: message,
            instructionID: instructionID,
            runID: runID,
            selectedOptionID: selectedOptionID
        )
    }

    private enum CodingKeys: String, CodingKey {
        case instructionID = "instruction_id"
        case taskID = "task_id"
        case message
        case runID = "run_id"
        case selectedOptionID = "selected_option_id"
        case clientSource = "client_source"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(instructionID, forKey: .instructionID)
        try container.encode(taskID, forKey: .taskID)
        try container.encode(message, forKey: .message)
        if let runID {
            try container.encode(runID, forKey: .runID)
        } else {
            try container.encodeNil(forKey: .runID)
        }
        if let selectedOptionID {
            try container.encode(selectedOptionID, forKey: .selectedOptionID)
        } else {
            try container.encodeNil(forKey: .selectedOptionID)
        }
        try container.encode(clientSource, forKey: .clientSource)
    }
}

public struct RemoteTaskInstructionReceipt: Equatable, Sendable {
    public let accepted: Bool
    public let duplicate: Bool
    public let instructionID: UUID
    public let sourceCommentID: Int64
    public let envelopeTaskID: String

    public init(
        accepted: Bool,
        duplicate: Bool,
        instructionID: UUID,
        sourceCommentID: Int64,
        envelopeTaskID: String
    ) {
        self.accepted = accepted
        self.duplicate = duplicate
        self.instructionID = instructionID
        self.sourceCommentID = sourceCommentID
        self.envelopeTaskID = envelopeTaskID
    }
}

public enum TaskInstructionCodecError: Error, Equatable, LocalizedError {
    case invalidReceipt

    public var errorDescription: String? {
        "The remote Astra instruction receipt did not match the required contract."
    }
}

public enum TaskInstructionCodec {
    private static let receiptKeys: Set<String> = [
        "accepted", "duplicate", "instruction_id", "source_comment_id", "envelope_task_id"
    ]
    private static let canonicalTaskIDPattern = "^t_[0-9a-f]{8}$"

    public static func encode(_ request: RemoteTaskInstructionRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(request)
    }

    public static func decodeReceipt(
        _ data: Data,
        expectedInstructionID: UUID
    ) throws -> RemoteTaskInstructionReceipt {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == receiptKeys,
              let accepted = strictBoolean(object["accepted"]), accepted,
              let duplicate = strictBoolean(object["duplicate"]),
              let instructionIDString = object["instruction_id"] as? String,
              let instructionID = UUID(uuidString: instructionIDString),
              instructionID == expectedInstructionID,
              let sourceCommentID = strictPositiveInteger(object["source_comment_id"]),
              let envelopeTaskID = object["envelope_task_id"] as? String,
              envelopeTaskID.range(
                of: canonicalTaskIDPattern,
                options: .regularExpression
              ) == envelopeTaskID.startIndex..<envelopeTaskID.endIndex else {
            throw TaskInstructionCodecError.invalidReceipt
        }
        return RemoteTaskInstructionReceipt(
            accepted: accepted,
            duplicate: duplicate,
            instructionID: instructionID,
            sourceCommentID: sourceCommentID,
            envelopeTaskID: envelopeTaskID
        )
    }

    private static func strictBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    private static func strictPositiveInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let integer = number.int64Value
        guard integer > 0, NSNumber(value: integer) == number else { return nil }
        return integer
    }
}

public protocol RemoteTaskInstructionSubmitting: Sendable {
    func submitTaskInstruction(
        _ request: RemoteTaskInstructionRequest
    ) async throws -> RemoteTaskInstructionReceipt
}

public enum HermesTaskInstructionCommand {
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

enum TaskInstructionHelperResource {
    static var bundle: Bundle {
#if SWIFT_PACKAGE
        return Bundle.module
#else
        return Bundle.main
#endif
    }

    static var url: URL? {
        bundle.url(forResource: "TaskInstructionHelper", withExtension: "py")
    }
}
