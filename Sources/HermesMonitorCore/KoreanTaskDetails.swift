import Foundation

public struct KoreanTaskDetailPresentation: Equatable, Sendable {
    public let statusLabel: String
    public let summary: String
    public let nextSteps: [String]
    public let userAction: String?
    public let sourceCommentID: Int64?

    public init(
        statusLabel: String,
        summary: String,
        nextSteps: [String],
        userAction: String?,
        sourceCommentID: Int64?
    ) {
        self.statusLabel = statusLabel
        self.summary = summary
        self.nextSteps = nextSteps
        self.userAction = userAction
        self.sourceCommentID = sourceCommentID
    }
}

public enum KoreanTaskDetails {
    private static let marker = "[DETAILS_KO]"
    private static let astraReplyMarker = "[ASTRA_REPLY_KO]"
    private static let summaryPrefix = "요약:"
    private static let nextStepsHeading = "다음 진행 선택지:"
    private static let userActionPrefix = "사용자 전용 조치:"
    private static let maximumSummaryLength = 240
    private static let maximumNextStepLength = 160
    private static let maximumNextStepCount = 3
    private static let maximumUserActionLength = 240

    public static func presentation(
        status: TaskVisualStatus,
        comments: [TaskComment]
    ) -> KoreanTaskDetailPresentation {
        let latest = comments
            .sorted(by: isEarlierComment)
            .reversed()
            .lazy
            .compactMap(parseAgentHandoff)
            .first

        if let latest {
            return KoreanTaskDetailPresentation(
                statusLabel: statusLabel(for: status),
                summary: latest.summary,
                nextSteps: latest.nextSteps,
                userAction: latest.userAction,
                sourceCommentID: latest.commentID
            )
        }

        return KoreanTaskDetailPresentation(
            statusLabel: statusLabel(for: status),
            summary: fallbackSummary(for: status),
            nextSteps: [],
            userAction: nil,
            sourceCommentID: nil
        )
    }

    private static func parseAgentHandoff(_ comment: TaskComment) -> ParsedHandoff? {
        guard comment.author != "user" else { return nil }
        let lines = comment.body
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let contractLines = lines.first == astraReplyMarker
            ? Array(lines.dropFirst())
            : lines

        guard contractLines.count >= 3,
              contractLines[0] == marker,
              contractLines[1].hasPrefix(summaryPrefix) else {
            return nil
        }

        let summary = String(contractLines[1].dropFirst(summaryPrefix.count))
            .trimmingCharacters(in: .whitespaces)
        guard isBoundedKoreanText(summary, maximumLength: maximumSummaryLength) else {
            return nil
        }

        if contractLines[2].hasPrefix(userActionPrefix) {
            guard contractLines.count == 3 else { return nil }
            let userAction = String(contractLines[2].dropFirst(userActionPrefix.count))
                .trimmingCharacters(in: .whitespaces)
            guard isBoundedKoreanText(userAction, maximumLength: maximumUserActionLength) else {
                return nil
            }
            return ParsedHandoff(
                commentID: comment.id,
                summary: summary,
                nextSteps: [],
                userAction: userAction
            )
        }

        guard contractLines[2] == nextStepsHeading else { return nil }
        let candidates = contractLines.dropFirst(3)
        guard !candidates.isEmpty, candidates.count <= maximumNextStepCount else {
            return nil
        }

        var nextSteps: [String] = []
        for (offset, line) in candidates.enumerated() {
            let expectedLabel = String(UnicodeScalar(65 + offset)!) + ". "
            guard line.hasPrefix(expectedLabel),
                  isBoundedKoreanText(line, maximumLength: maximumNextStepLength) else {
                return nil
            }
            nextSteps.append(line)
        }

        return ParsedHandoff(
            commentID: comment.id,
            summary: summary,
            nextSteps: nextSteps,
            userAction: nil
        )
    }

    private static func isEarlierComment(_ lhs: TaskComment, _ rhs: TaskComment) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id < rhs.id
    }

    private static func isBoundedKoreanText(_ text: String, maximumLength: Int) -> Bool {
        !text.isEmpty &&
            text.count <= maximumLength &&
            text.unicodeScalars.contains { scalar in
                (0xAC00 ... 0xD7A3).contains(scalar.value)
            }
    }

    private static func statusLabel(for status: TaskVisualStatus) -> String {
        switch status {
        case .todo: return "대기"
        case .ready: return "준비됨"
        case .running: return "진행 중"
        case .blocked: return "차단됨"
        case .done: return "완료됨"
        case .archived: return "보관됨"
        case .failed: return "실패"
        }
    }

    private static func fallbackSummary(for status: TaskVisualStatus) -> String {
        switch status {
        case .todo: return "작업이 대기 중이며 최신 한국어 인계가 없습니다."
        case .ready: return "작업을 시작할 준비가 되었으며 최신 한국어 인계가 없습니다."
        case .running: return "작업이 진행 중이며 최신 한국어 인계가 없습니다."
        case .blocked: return "작업이 차단되었으며 최신 한국어 인계가 없습니다."
        case .done: return "작업이 완료되었으며 최신 한국어 인계가 없습니다."
        case .archived: return "작업이 보관되었으며 최신 한국어 인계가 없습니다."
        case .failed: return "작업 실행이 실패했으며 최신 한국어 인계가 없습니다."
        }
    }

    private struct ParsedHandoff {
        let commentID: Int64
        let summary: String
        let nextSteps: [String]
        let userAction: String?
    }
}
