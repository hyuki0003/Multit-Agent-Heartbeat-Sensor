import AppKit
import XCTest
@testable import HermesMonitorApp
import HermesMonitorCore

@MainActor
final class TaskCommentsRenderTests: XCTestCase {
    func testRendersAgentActionableCommentsWindowWhenArtifactPathIsRequested() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment[
            "HERMES_MONITOR_COMMENTS_AGENT_RENDER"
        ] else {
            throw XCTSkip("Set HERMES_MONITOR_COMMENTS_AGENT_RENDER to capture the agent-actionable state")
        }
        let comments = [
            TaskComment(
                id: 41,
                taskID: Self.taskID,
                author: "user",
                body: "A. 독립 검증 게이트를 먼저 실행해 주세요.\n<!-- hermes-monitor-instruction:11111111-1111-1111-1111-111111111111 -->",
                createdAt: Date(timeIntervalSince1970: 1_750_000_100)
            ),
            TaskComment(
                id: 42,
                taskID: Self.taskID,
                author: "astra",
                body: """
                [ASTRA_REPLY_KO]
                [DETAILS_KO]
                요약: Comments 창과 Astra 지시 계약 구현을 완료했습니다.
                다음 진행 선택지:
                A. focused 검증 결과를 리뷰한다
                B. 전체 Swift 및 Integration 결과를 리뷰한다
                C. XcodeGen 렌더 증거를 확인한다
                """,
                createdAt: Date(timeIntervalSince1970: 1_750_000_200)
            )
        ]

        let report = TaskCommentsReport(task: makeTask(title: "Agent-actionable Clinical Report"), comments: comments)
        XCTAssertEqual(report.sourceCommentID, 42)
        XCTAssertEqual(report.prefillOptions.map(\.id), ["A", "B", "C"])

        try await renderCommentsWindow(
            outputPath: outputPath,
            title: "Agent-actionable Clinical Report",
            comments: comments
        )
    }

    func testRendersHumanOnlyCommentsWindowWhenArtifactPathIsRequested() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment[
            "HERMES_MONITOR_COMMENTS_HUMAN_RENDER"
        ] else {
            throw XCTSkip("Set HERMES_MONITOR_COMMENTS_HUMAN_RENDER to capture the human-only state")
        }
        let comments = [
            TaskComment(
                id: 51,
                taskID: Self.taskID,
                author: "astra",
                body: """
                [ASTRA_REPLY_KO]
                [DETAILS_KO]
                요약: macOS 접근성 권한 승인이 필요해 작업이 차단되었습니다.
                사용자 전용 조치: 시스템 설정에서 Hermes Monitor의 접근성 권한을 승인하세요.
                """,
                createdAt: Date(timeIntervalSince1970: 1_750_000_200)
            )
        ]

        let report = TaskCommentsReport(task: makeTask(title: "Human-only Clinical Report"), comments: comments)
        XCTAssertEqual(report.sourceCommentID, 51)
        XCTAssertEqual(
            report.userAction,
            "시스템 설정에서 Hermes Monitor의 접근성 권한을 승인하세요."
        )
        XCTAssertTrue(report.prefillOptions.isEmpty)

        try await renderCommentsWindow(
            outputPath: outputPath,
            title: "Human-only Clinical Report",
            comments: comments
        )
    }

    private func renderCommentsWindow(
        outputPath: String,
        title: String,
        comments: [TaskComment]
    ) async throws {
        let task = makeTask(title: title)
        let kanban = KanbanSnapshot(
            tasks: [task],
            runs: [],
            events: [],
            comments: comments,
            links: []
        )
        let snapshot = HermesMonitorSnapshot(
            kanban: kanban,
            state: StateSnapshot(sessions: []),
            tasks: TaskCorrelator().correlate(tasks: [task], runs: [], sessions: []),
            logTails: [:],
            warnings: [],
            refreshedAt: Date(timeIntervalSince1970: 1_750_000_300)
        )
        let viewModel = MonitorViewModel(client: RenderMonitorService(snapshot: snapshot))
        await viewModel.refresh()
        XCTAssertEqual(viewModel.snapshot?.tasks.first?.id, Self.taskID)

        let coordinator = TaskCommentsWindowCoordinator(viewModel: viewModel)
        let controller = coordinator.windowController(taskID: Self.taskID)
        guard let window = controller.window, let contentView = window.contentView else {
            return XCTFail("Comments window did not provide renderable content")
        }
        window.setContentSize(NSSize(width: 600, height: 840))
        window.layoutIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        contentView.layoutSubtreeIfNeeded()

        guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            return XCTFail("Could not allocate a Comments window bitmap")
        }
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let sourceImage = bitmap.cgImage,
              let context = CGContext(
                data: nil,
                width: bitmap.pixelsWide,
                height: bitmap.pixelsHigh,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return XCTFail("Could not allocate an opaque Comments window bitmap")
        }
        let pixelBounds = CGRect(
            x: 0,
            y: 0,
            width: bitmap.pixelsWide,
            height: bitmap.pixelsHigh
        )
        context.setFillColor(NSColor.black.cgColor)
        context.fill(pixelBounds)
        context.draw(sourceImage, in: pixelBounds)
        guard let compositedImage = context.makeImage() else {
            return XCTFail("Could not composite the Comments window bitmap")
        }
        let composited = NSBitmapImageRep(cgImage: compositedImage)
        XCTAssertEqual(
            composited.colorAt(x: 0, y: 0)?.alphaComponent ?? 0,
            1,
            accuracy: 0.001
        )
        guard let png = composited.representation(
            using: NSBitmapImageRep.FileType.png,
            properties: [:]
        ) else {
            return XCTFail("Could not encode the Comments window bitmap")
        }
        try png.write(
            to: URL(fileURLWithPath: outputPath),
            options: Data.WritingOptions.atomic
        )
        XCTAssertGreaterThan(png.count, 10_000)
    }

    private static let taskID = "t_aca6317b"

    private func makeTask(title: String) -> KanbanTask {
        KanbanTask(
            id: Self.taskID,
            title: title,
            status: .blocked,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            completedAt: nil
        )
    }
}

private actor RenderMonitorService: HermesMonitorServing {
    let snapshot: HermesMonitorSnapshot

    init(snapshot: HermesMonitorSnapshot) {
        self.snapshot = snapshot
    }

    func refresh() async throws -> HermesMonitorSnapshot {
        snapshot
    }

    func authoritativeTaskStatus(taskID: String) async throws -> KanbanTaskStatus? {
        snapshot.kanban.tasks.first(where: { $0.id == taskID })?.status
    }

    func archiveDoneTask(taskID: String) async throws {}
}
