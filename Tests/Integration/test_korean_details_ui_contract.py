import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
APP = ROOT / "Sources" / "HermesMonitorApp"


class KoreanDetailsUIContractTests(unittest.TestCase):
    def test_task_cards_do_not_accept_or_render_raw_log_lines(self):
        task_card = (APP / "TaskCardView.swift").read_text(encoding="utf-8")
        task_list = (APP / "TaskListView.swift").read_text(encoding="utf-8")

        self.assertNotIn("logLines", task_card)
        self.assertNotIn("logLines", task_list)
        self.assertNotIn("showsLog", task_card)
        self.assertNotIn('title: "Log', task_card)
        self.assertNotIn('"No log"', task_card)
        self.assertNotIn("ScrollView(.horizontal", task_card)
        self.assertNotIn(".fixedSize(horizontal: true", task_card)

    def test_comments_window_renders_korean_summary_and_mutually_exclusive_handoff_actions(self):
        task_card = (APP / "TaskCardView.swift").read_text(encoding="utf-8")
        comments_window = (APP / "TaskCommentsWindow.swift").read_text(encoding="utf-8")

        self.assertIn('title: "Comments"', task_card)
        self.assertNotIn("TaskDetailView(", task_card)
        self.assertIn("KoreanTaskDetails.presentation(", comments_window)
        self.assertIn("case .requiresUserAction", comments_window)
        self.assertIn("case .summary", comments_window)
        self.assertIn("prefillOptions = []", comments_window)
        self.assertIn('Text("Clinical Comments")', comments_window)
        self.assertIn(
            'Text("운영 작업 보고서 · 개인·의료 정보는 표시하지 않음")',
            comments_window,
        )
        self.assertIn('Text("요약")', comments_window)
        self.assertIn('Text("권고")', comments_window)

    def test_periodic_liveness_refresh_is_isolated_from_the_whole_task_card(self):
        task_card = (APP / "TaskCardView.swift").read_text(encoding="utf-8")
        heartbeat_views = (APP / "HeartbeatViews.swift").read_text(encoding="utf-8")

        self.assertNotIn("TimelineView", task_card)
        self.assertIn("struct LiveHeartbeatIndicator", heartbeat_views)
        self.assertIn("struct TaskLivenessSummaryView", heartbeat_views)
        self.assertIn("TimelineView(.periodic", heartbeat_views)


if __name__ == "__main__":
    unittest.main()
