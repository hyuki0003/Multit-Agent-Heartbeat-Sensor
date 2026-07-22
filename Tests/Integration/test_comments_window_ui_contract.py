from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
TASK_CARD = ROOT / "Sources/HermesMonitorApp/TaskCardView.swift"
TASK_DETAIL = ROOT / "Sources/HermesMonitorApp/TaskDetailView.swift"
TASK_LIST = ROOT / "Sources/HermesMonitorApp/TaskListView.swift"
COMMENTS_WINDOW = ROOT / "Sources/HermesMonitorApp/TaskCommentsWindow.swift"


class CommentsWindowUIContractTests(unittest.TestCase):
    def test_task_detail_has_no_inline_comments_section(self):
        source = TASK_DETAIL.read_text(encoding="utf-8")
        task_card = TASK_CARD.read_text(encoding="utf-8")
        self.assertNotIn("let comments: [TaskComment]", source)
        self.assertNotIn('sectionTitle("Comments")', source)
        self.assertNotIn("ForEach(comments", source)
        self.assertNotIn("TaskDetailView(", task_card)

    def test_expanded_and_compact_cards_expose_comments_action(self):
        card = TASK_CARD.read_text(encoding="utf-8")
        task_list = TASK_LIST.read_text(encoding="utf-8")
        self.assertIn('title: "Comments"', card)
        self.assertIn("onShowComments", card)
        self.assertIn('accessibilityLabel("Open Comments for \\(item.task.title)")', task_list)
        self.assertIn("onShowComments(item)", task_list)

    def test_comments_live_in_a_separate_appkit_window_with_required_copy(self):
        source = COMMENTS_WINDOW.read_text(encoding="utf-8")
        self.assertIn("final class TaskCommentsWindowCoordinator", source)
        self.assertIn("NSWindowController", source)
        self.assertIn('Text("Clinical Comments")', source)
        self.assertIn('Text("운영 작업 보고서 · 개인·의료 정보는 표시하지 않음")', source)
        self.assertIn('Text("요약")', source)
        self.assertIn('Text("권고")', source)
        self.assertIn('Text("사용자 조치")', source)
        self.assertIn('Text("사용자만 수행 가능")', source)
        self.assertIn('Text("아직 댓글이 없습니다")', source)
        self.assertIn('Text("Astra 접수 완료")', source)
        self.assertIn("keyboardShortcut(.return, modifiers: .command)", source)

    def test_report_header_and_composer_expose_required_hierarchy_and_states(self):
        source = COMMENTS_WINDOW.read_text(encoding="utf-8")
        self.assertIn("task.task.assignee ?? task.currentRun?.profile ?? \"unassigned\"", source)
        self.assertIn("Text(reportUpdatedAt(for: task), style: .relative)", source)
        self.assertIn("@FocusState private var composerFocused", source)
        self.assertIn(".focused($composerFocused)", source)
        self.assertIn("Text(composer.placeholder(for: report))", source)
        self.assertIn('Text("Astra로 전송 중")', source)
        self.assertIn('Text("Astra 접수 완료")', source)
        self.assertIn('Text("재시도")', source)
        self.assertIn("Color.secondary.opacity(0.06)", source)


if __name__ == "__main__":
    unittest.main()
