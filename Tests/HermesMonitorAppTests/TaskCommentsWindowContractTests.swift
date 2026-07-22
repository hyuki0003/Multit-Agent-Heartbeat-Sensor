import Foundation
import XCTest
@testable import HermesMonitorApp
import HermesMonitorCore

@MainActor
final class TaskCommentsWindowContractTests: XCTestCase {
    func testWindowCoordinatorReusesOneControllerPerTaskID() {
        let viewModel = MonitorViewModel(client: nil)
        let coordinator = TaskCommentsWindowCoordinator(viewModel: viewModel)

        let first = coordinator.windowController(taskID: "t_11111111")
        let repeated = coordinator.windowController(taskID: "t_11111111")
        let other = coordinator.windowController(taskID: "t_22222222")

        XCTAssertTrue(first === repeated)
        XCTAssertFalse(first === other)
        let firstWindow = try! XCTUnwrap(first.window)
        XCTAssertEqual(firstWindow.title, "Hermes Monitor — Comments · t_11111111")
        XCTAssertEqual(firstWindow.frame.width, 600, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(firstWindow.minSize.height, 600)
    }

    func testAgentRecommendationPrefillUsesExactOptionAndNeverSubmits() {
        let state = TaskCommentsComposerState()
        var submissions = 0
        state.onSubmit = { submissions += 1 }

        state.prefill(option: "B. 승인된 최소 패치를 적용하고 검증하세요.")

        XCTAssertEqual(state.draft, "B. 승인된 최소 패치를 적용하고 검증하세요.")
        XCTAssertEqual(state.selectedOptionID, "B")
        XCTAssertEqual(submissions, 0)
    }

    func testHumanOnlyReportSuppressesAgentOptions() {
        let details = KoreanTaskDetailPresentation(
            statusLabel: "차단됨",
            summary: "사용자 승인이 있어야 다음 단계로 진행할 수 있습니다.",
            nextSteps: ["A. 이 선택지는 표시되면 안 됩니다."],
            userAction: "시스템 설정에서 접근성 권한을 직접 승인하세요.",
            sourceCommentID: 7
        )

        let report = TaskCommentsReport(details: details)

        XCTAssertEqual(report.userAction, "시스템 설정에서 접근성 권한을 직접 승인하세요.")
        XCTAssertTrue(report.agentOptions.isEmpty)
    }

    func testAgentActionableReportExposesOptionsWithoutHumanOnlyCallout() {
        let details = KoreanTaskDetailPresentation(
            statusLabel: "차단됨",
            summary: "검증 범위를 선택하면 에이전트가 다음 단계를 수행할 수 있습니다.",
            nextSteps: ["A. 빠른 검증", "B. 전체 검증"],
            userAction: nil,
            sourceCommentID: 8
        )

        let report = TaskCommentsReport(details: details)

        XCTAssertNil(report.userAction)
        XCTAssertEqual(report.agentOptions, ["A. 빠른 검증", "B. 전체 검증"])
    }

    func testComposerStateCoversDeterministicDeliveryAndFocusTransitions() {
        let state = TaskCommentsComposerState()
        XCTAssertEqual(state.deliveryState, .idle)
        XCTAssertEqual(state.focusRequestID, 0)

        state.prefill(option: "B. 수정 사항을 요청합니다.")
        XCTAssertEqual(state.selectedOptionID, "B")
        XCTAssertEqual(state.focusRequestID, 1)

        state.beginSending()
        XCTAssertEqual(state.deliveryState, .sending)
        state.accept(notice: "comment #41 · envelope t_abcdef12")
        XCTAssertEqual(state.deliveryState, .accepted("comment #41 · envelope t_abcdef12"))
        XCTAssertEqual(state.draft, "")

        state.prefill(option: "A. 패치를 검토합니다.")
        state.fail(message: "network unavailable")
        XCTAssertEqual(state.deliveryState, .failed("network unavailable"))
        state.beginSending()
        XCTAssertEqual(state.deliveryState, .sending)
    }

    func testHumanOnlyReportUsesExactActionAsComposerPlaceholder() {
        let report = TaskCommentsReport(
            details: KoreanTaskDetailPresentation(
                statusLabel: "차단됨",
                summary: "사용자 권한이 필요합니다.",
                nextSteps: [],
                userAction: "시스템 설정에서 접근성 권한을 허용하세요.",
                sourceCommentID: 44
            )
        )

        XCTAssertEqual(
            TaskCommentsComposerState().placeholder(for: report),
            "시스템 설정에서 접근성 권한을 허용하세요."
        )
    }

    func testUserAuthoredAstraMarkerRemainsUserTimelineProvenance() {
        let entry = TaskCommentsTimelineEntry(
            comment: TaskComment(
                id: 17,
                taskID: "t_12345678",
                author: "user",
                body: "[ASTRA_REPLY_KO]\n사용자 입력",
                createdAt: Date(timeIntervalSince1970: 17)
            )
        )

        XCTAssertEqual(entry.role, .user)
    }
}
