import Foundation
import XCTest
@testable import HermesMonitorCore

final class RemoteTaskInstructionSubmittingTests: XCTestCase {
    func testRequestAcceptsCanonicalUTF8PayloadAndPreservesRunContext() throws {
        let instructionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        let request = try RemoteTaskInstructionRequest(
            taskID: "t_b672f7a7",
            message: "옵션 B로 진행하고 결과를 한국어로 보고해 주세요.",
            instructionID: instructionID,
            runID: 42,
            selectedOptionID: "B"
        )
        let payload = try TaskInstructionCodec.encode(request)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), [
            "instruction_id", "task_id", "message", "run_id", "selected_option_id", "client_source"
        ])
        XCTAssertEqual(object["instruction_id"] as? String, instructionID.uuidString.lowercased())
        XCTAssertEqual(object["task_id"] as? String, "t_b672f7a7")
        XCTAssertEqual(object["message"] as? String, request.message)
        XCTAssertEqual(object["run_id"] as? Int, 42)
        XCTAssertEqual(object["selected_option_id"] as? String, "B")
        XCTAssertEqual(object["client_source"] as? String, "hermes-monitor")
    }

    func testPendingTaskWithHistoryEncodesExplicitNullRunBinding() throws {
        let task = KanbanTask(
            id: "t_b672f7a7",
            title: "Pending",
            status: .ready,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let historicalRun = TaskRun(
            id: 9,
            taskID: task.id,
            profile: "rune-implementer",
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 101),
            outcome: .completed
        )
        let correlated = try XCTUnwrap(
            TaskCorrelator().correlate(tasks: [task], runs: [historicalRun], sessions: []).first
        )

        XCTAssertEqual(correlated.currentRun?.id, historicalRun.id)
        let request = try RemoteTaskInstructionRequest(
            task: correlated,
            message: "대기 중인 작업을 진행해 주세요.",
            instructionID: UUID(uuidString: "21111111-2222-4333-8444-555555555555")!
        )
        let payload = try TaskInstructionCodec.encode(request)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), [
            "instruction_id", "task_id", "message", "run_id", "selected_option_id", "client_source"
        ])
        XCTAssertTrue(object["run_id"] is NSNull)
    }

    func testBlockedTaskBindsNewestDurableRunIDInsteadOfDisplayRun() throws {
        let task = KanbanTask(
            id: "t_b672f7a7",
            title: "Blocked",
            status: .blocked,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let displayRun = TaskRun(
            id: 9,
            taskID: task.id,
            profile: "rune-implementer",
            status: .blocked,
            startedAt: Date(timeIntervalSince1970: 300),
            endedAt: Date(timeIntervalSince1970: 301),
            outcome: .blocked
        )
        let authoritativeRun = TaskRun(
            id: 10,
            taskID: task.id,
            profile: "rune-implementer",
            status: .blocked,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 101),
            outcome: .blocked
        )
        let correlated = try XCTUnwrap(
            TaskCorrelator().correlate(
                tasks: [task],
                runs: [displayRun, authoritativeRun],
                sessions: []
            ).first
        )

        XCTAssertEqual(correlated.currentRun?.id, displayRun.id)
        let request = try RemoteTaskInstructionRequest(
            task: correlated,
            message: "차단된 실행을 이어서 처리해 주세요."
        )
        XCTAssertEqual(request.runID, authoritativeRun.id)
    }

    func testRunningTaskBindsOnlyExactCurrentRun() throws {
        let task = KanbanTask(
            id: "t_b672f7a7",
            title: "Running",
            status: .running,
            createdAt: Date(timeIntervalSince1970: 1),
            currentRunID: 20
        )
        let currentRun = TaskRun(
            id: 20,
            taskID: task.id,
            profile: "rune-implementer",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let newerHistoricalRun = TaskRun(
            id: 21,
            taskID: task.id,
            profile: "rune-implementer",
            status: .blocked,
            startedAt: Date(timeIntervalSince1970: 200),
            endedAt: Date(timeIntervalSince1970: 201),
            outcome: .blocked
        )
        let correlated = try XCTUnwrap(
            TaskCorrelator().correlate(
                tasks: [task],
                runs: [newerHistoricalRun, currentRun],
                sessions: []
            ).first
        )

        let request = try RemoteTaskInstructionRequest(
            task: correlated,
            message: "현재 실행에 지시를 전달해 주세요."
        )
        XCTAssertEqual(request.runID, currentRun.id)
    }

    func testRunningTaskRejectsCrossTaskCurrentRunEvenWithDisplayFallback() throws {
        let task = KanbanTask(
            id: "t_b672f7a7",
            title: "Running",
            status: .running,
            createdAt: Date(timeIntervalSince1970: 1),
            currentRunID: 30
        )
        let displayFallback = TaskRun(
            id: 29,
            taskID: task.id,
            profile: "rune-implementer",
            status: .blocked,
            startedAt: Date(timeIntervalSince1970: 200),
            endedAt: Date(timeIntervalSince1970: 201),
            outcome: .blocked
        )
        let crossTaskRun = TaskRun(
            id: 30,
            taskID: "t_aaaaaaaa",
            profile: "rune-implementer",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let correlated = try XCTUnwrap(
            TaskCorrelator().correlate(
                tasks: [task],
                runs: [displayFallback, crossTaskRun],
                sessions: []
            ).first
        )

        XCTAssertEqual(correlated.currentRun?.id, displayFallback.id)
        XCTAssertThrowsError(
            try RemoteTaskInstructionRequest(task: correlated, message: "전달하면 안 됩니다.")
        ) { error in
            XCTAssertEqual(
                error as? TaskInstructionValidationError,
                .unavailableTaskBinding(task.id)
            )
        }
    }

    func testBlockedTaskRejectsWhenNewestRunHasNoValidBinding() throws {
        let task = KanbanTask(
            id: "t_b672f7a7",
            title: "Blocked without authoritative run",
            status: .blocked,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let terminalRun = TaskRun(
            id: 40,
            taskID: task.id,
            profile: "rune-implementer",
            status: .done,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 101),
            outcome: .completed
        )
        let correlated = try XCTUnwrap(
            TaskCorrelator().correlate(tasks: [task], runs: [terminalRun], sessions: []).first
        )

        XCTAssertThrowsError(
            try RemoteTaskInstructionRequest(task: correlated, message: "전달하면 안 됩니다.")
        ) { error in
            XCTAssertEqual(
                error as? TaskInstructionValidationError,
                .unavailableTaskBinding(task.id)
            )
        }
    }

    func testRequestRejectsInvalidTaskIDsEmptyMessagesAndOversizedUTF8() {
        let invalidTaskIDs = ["", "t_1", "t_B672F7A7", "t_b672f7ag", "../t_b672f7a7", "t_b672f7a7;id"]
        for taskID in invalidTaskIDs {
            XCTAssertThrowsError(
                try RemoteTaskInstructionRequest(taskID: taskID, message: "진행해 주세요.")
            ) { error in
                XCTAssertEqual(error as? TaskInstructionValidationError, .invalidTaskID(taskID))
            }
        }

        for message in ["", "  \n\t"] {
            XCTAssertThrowsError(
                try RemoteTaskInstructionRequest(taskID: "t_b672f7a7", message: message)
            ) { error in
                XCTAssertEqual(error as? TaskInstructionValidationError, .emptyMessage)
            }
        }

        let oversized = String(repeating: "가", count: 1_334)
        XCTAssertGreaterThan(oversized.utf8.count, RemoteTaskInstructionRequest.maximumMessageBytes)
        XCTAssertThrowsError(
            try RemoteTaskInstructionRequest(taskID: "t_b672f7a7", message: oversized)
        ) { error in
            XCTAssertEqual(
                error as? TaskInstructionValidationError,
                .messageTooLarge(maximumBytes: RemoteTaskInstructionRequest.maximumMessageBytes)
            )
        }
    }

    func testRemoteCommandCarriesOnlyTrustedHelperAndFixedRoutingInArgv() throws {
        let messageSentinel = "never-place-this-message-in-argv-$(touch /tmp/pwned)"
        let request = try RemoteTaskInstructionRequest(
            taskID: "t_b672f7a7",
            message: messageSentinel,
            instructionID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let payload = try TaskInstructionCodec.encode(request)
        let command = HermesTaskInstructionCommand.remoteCommand(helper: "print('trusted helper')")

        XCTAssertEqual(
            command,
            "/usr/bin/env HERMES_KANBAN_BOARD=default " +
                "HERMES_KANBAN_DB=/home/dhlee/.hermes/kanban.db " +
                "PYTHONPATH=/home/dhlee/.hermes/hermes-agent " +
                "/home/dhlee/.hermes/hermes-agent/venv/bin/python -c 'print('\\''trusted helper'\\'')'"
        )
        XCTAssertFalse(command.contains(messageSentinel))
        XCTAssertFalse(command.contains(request.taskID))
        XCTAssertFalse(command.contains(request.instructionID.uuidString.lowercased()))
        XCTAssertTrue(String(decoding: payload, as: UTF8.self).contains(messageSentinel))
    }

    func testReceiptDecoderRequiresExactAcceptedContract() throws {
        let instructionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let data = Data(
            """
            {"accepted":true,"duplicate":false,"instruction_id":"11111111-2222-3333-4444-555555555555","source_comment_id":17,"envelope_task_id":"t_1234abcd"}
            """.utf8
        )

        let receipt = try TaskInstructionCodec.decodeReceipt(
            data,
            expectedInstructionID: instructionID
        )

        XCTAssertTrue(receipt.accepted)
        XCTAssertFalse(receipt.duplicate)
        XCTAssertEqual(receipt.instructionID, instructionID)
        XCTAssertEqual(receipt.sourceCommentID, 17)
        XCTAssertEqual(receipt.envelopeTaskID, "t_1234abcd")

        let invalidReceipts = [
            #"{"accepted":false,"duplicate":false,"instruction_id":"11111111-2222-3333-4444-555555555555","source_comment_id":17,"envelope_task_id":"t_1234abcd"}"#,
            #"{"accepted":true,"duplicate":false,"instruction_id":"11111111-2222-3333-4444-555555555555","source_comment_id":0,"envelope_task_id":"t_1234abcd"}"#,
            #"{"accepted":true,"duplicate":false,"instruction_id":"11111111-2222-3333-4444-555555555555","source_comment_id":17,"envelope_task_id":"bad"}"#,
            #"{"accepted":true,"duplicate":false,"instruction_id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","source_comment_id":17,"envelope_task_id":"t_1234abcd"}"#,
            #"{"accepted":true,"duplicate":false,"instruction_id":"11111111-2222-3333-4444-555555555555","source_comment_id":17,"envelope_task_id":"t_1234abcd","extra":"no"}"#,
        ]
        for invalid in invalidReceipts {
            XCTAssertThrowsError(
                try TaskInstructionCodec.decodeReceipt(
                    Data(invalid.utf8),
                    expectedInstructionID: instructionID
                )
            )
        }
    }

    func testInstructionDiagnosticsRedactMessageAndCredentialBeforeBounding() {
        let credential = "credential-must-not-leak"
        let message = "사용자 메시지도 진단에 남으면 안 됩니다"
        let output = Data((String(repeating: "x", count: 9_000) + message).utf8)
        let error = Data("ssh failed: \(credential) \(message)".utf8)

        let diagnostics = OpenSSHTransport.instructionDiagnostics(
            output: output,
            error: error,
            credentialSecret: credential,
            message: message
        )

        XCTAssertFalse(diagnostics.contains(credential))
        XCTAssertFalse(diagnostics.contains(message))
        XCTAssertTrue(diagnostics.contains("<redacted>"))
        XCTAssertLessThanOrEqual(diagnostics.utf8.count, 8 * 1_024)
    }

    func testTaskInstructionHelperIsBundled() {
        XCTAssertNotNil(TaskInstructionHelperResource.url)
    }
}
