import XCTest
@testable import HermesMonitorCore

final class KoreanTaskDetailsTests: XCTestCase {
    func testLatestValidKoreanHandoffProvidesBoundedProgressionChoices() {
        let comments = [
            makeComment(
                id: 1,
                body: """
                [DETAILS_KO]
                요약: 이전 한국어 요약입니다.
                다음 진행 선택지:
                A. 이전 작업을 계속합니다.
                """
            ),
            makeComment(
                id: 2,
                body: """
                [DETAILS_KO]
                Summary: this malformed English handoff must be ignored.
                """
            ),
            makeComment(
                id: 3,
                body: """
                [DETAILS_KO]
                요약: 검토 가능한 패치가 준비되었습니다.
                다음 진행 선택지:
                A. 패치를 검토합니다.
                B. 수정 사항을 요청합니다.
                C. 패치를 승인합니다.
                """
            ),
            makeComment(
                id: 4,
                body: """
                [DETAILS_KO]
                요약: 선택지가 너무 많아 무효인 최신 인계입니다.
                다음 진행 선택지:
                A. 첫 번째 선택지입니다.
                B. 두 번째 선택지입니다.
                C. 세 번째 선택지입니다.
                D. 허용되지 않는 네 번째 선택지입니다.
                """
            )
        ]

        let details = KoreanTaskDetails.presentation(status: .blocked, comments: comments)

        XCTAssertEqual(details.statusLabel, "차단됨")
        XCTAssertEqual(details.summary, "검토 가능한 패치가 준비되었습니다.")
        XCTAssertEqual(
            details.nextSteps,
            ["A. 패치를 검토합니다.", "B. 수정 사항을 요청합니다.", "C. 패치를 승인합니다."]
        )
        XCTAssertNil(details.userAction)
        XCTAssertEqual(details.sourceCommentID, 3)
    }

    func testHumanOnlyHandoffExposesExactActionWithoutProgressionChoices() {
        let comments = [
            makeComment(
                id: 4,
                body: """
                [DETAILS_KO]
                요약: 사용자의 접근성 권한 승인이 필요합니다.
                사용자 전용 조치: macOS 시스템 설정에서 Hermes Monitor의 접근성 권한을 허용하세요.
                """
            )
        ]

        let details = KoreanTaskDetails.presentation(status: .blocked, comments: comments)

        XCTAssertEqual(details.summary, "사용자의 접근성 권한 승인이 필요합니다.")
        XCTAssertEqual(
            details.userAction,
            "macOS 시스템 설정에서 Hermes Monitor의 접근성 권한을 허용하세요."
        )
        XCTAssertTrue(details.nextSteps.isEmpty)
        XCTAssertEqual(details.sourceCommentID, 4)
    }

    func testAstraReplyMarkerMayPrecedeClinicalReportContract() {
        let comments = [
            makeComment(
                id: 9,
                body: """
                [ASTRA_REPLY_KO]
                [DETAILS_KO]
                요약: Astra가 임상형 진행 보고서를 준비했습니다.
                다음 진행 선택지:
                A. 보고서 권고대로 진행합니다.
                B. 추가 근거를 요청합니다.
                """
            )
        ]

        let details = KoreanTaskDetails.presentation(status: .blocked, comments: comments)

        XCTAssertEqual(details.summary, "Astra가 임상형 진행 보고서를 준비했습니다.")
        XCTAssertEqual(
            details.nextSteps,
            ["A. 보고서 권고대로 진행합니다.", "B. 추가 근거를 요청합니다."]
        )
        XCTAssertEqual(details.sourceCommentID, 9)
    }

    func testMissingValidHandoffUsesDeterministicKoreanTaskStateFallback() {
        let invalidEnglishComment = makeComment(
            id: 5,
            body: """
            [DETAILS_KO]
            요약: Korean summary with no valid action contract.
            """
        )

        let blocked = KoreanTaskDetails.presentation(status: .blocked, comments: [])
        let running = KoreanTaskDetails.presentation(status: .running, comments: [invalidEnglishComment])

        XCTAssertEqual(blocked.statusLabel, "차단됨")
        XCTAssertEqual(blocked.summary, "작업이 차단되었으며 최신 한국어 인계가 없습니다.")
        XCTAssertEqual(running.statusLabel, "진행 중")
        XCTAssertEqual(running.summary, "작업이 진행 중이며 최신 한국어 인계가 없습니다.")
        XCTAssertNil(blocked.sourceCommentID)
        XCTAssertNil(running.sourceCommentID)
    }

    func testUserAuthoredDetailsMarkerCannotSpoofAgentClinicalReport() {
        let spoofed = TaskComment(
            id: 99,
            taskID: "t_12345678",
            author: "user",
            body: """
            [DETAILS_KO]
            요약: 사용자가 작성한 마커는 에이전트 보고서가 아닙니다.
            다음 진행 선택지:
            A. 이 선택지는 노출되면 안 됩니다.
            """,
            createdAt: Date(timeIntervalSince1970: 99)
        )

        let details = KoreanTaskDetails.presentation(status: .blocked, comments: [spoofed])

        XCTAssertEqual(details.summary, "작업이 차단되었으며 최신 한국어 인계가 없습니다.")
        XCTAssertTrue(details.nextSteps.isEmpty)
        XCTAssertNil(details.sourceCommentID)
    }

    private func makeComment(id: Int64, body: String) -> TaskComment {
        TaskComment(
            id: id,
            taskID: "t_12345678",
            author: "rune-implementer",
            body: body,
            createdAt: Date(timeIntervalSince1970: TimeInterval(id))
        )
    }
}
