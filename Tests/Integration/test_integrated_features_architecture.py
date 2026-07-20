import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
CORE = ROOT / "Sources" / "HermesMonitorCore"
APP = ROOT / "Sources" / "HermesMonitorApp"


class IntegratedFeatureArchitectureTests(unittest.TestCase):
    def test_archive_is_fixed_bounded_and_never_hard_deletes(self):
        archive = (CORE / "RemoteKanbanArchiving.swift").read_text(encoding="utf-8")
        transport = (CORE / "OpenSSHTransport.swift").read_text(encoding="utf-8")
        client = (CORE / "HermesMonitorClient.swift").read_text(encoding="utf-8")

        self.assertIn('"^t_[0-9a-f]{8}$"', archive)
        self.assertIn("HERMES_KANBAN_BOARD=default", archive)
        self.assertIn("HERMES_KANBAN_DB=/home/dhlee/.hermes/kanban.db", archive)
        self.assertIn("/hermes kanban archive ", archive)
        self.assertNotIn("archive --rm", archive)
        self.assertNotIn("sqlite3", archive.lower())
        self.assertIn("archiveProcessTimeoutSeconds: TimeInterval = 20", transport)
        self.assertIn("waitForArchiveProcess", transport)
        self.assertIn("terminateAndReap(process)", transport)
        self.assertIn("BoundedProcessOutputCapture", transport)
        self.assertIn("process.standardOutput = outputCapture.pipe", transport)
        self.assertIn("process.standardError = errorCapture.pipe", transport)
        self.assertNotIn("HermesMonitor-archive-", transport)
        self.assertNotIn("outputURL: outputURL", transport)
        self.assertIn("SSHAskPassEnvironment.make(", transport)
        self.assertIn("RemoteArchiveWorkflow", archive)
        self.assertIn("HermesMonitorServing", client)
        self.assertIn("authoritativeTaskStatus", archive)
        self.assertIn("residual TOCTOU", archive)
        workflow = archive.split("public actor RemoteArchiveWorkflow", 1)[1]
        self.assertLess(
            workflow.index("authoritativeTaskStatus"),
            workflow.index("service.archiveDoneTask"),
        )

    def test_archive_diagnostics_redact_before_final_truncation(self):
        transport = (CORE / "OpenSSHTransport.swift").read_text(encoding="utf-8")
        diagnostics = transport.split("static func archiveDiagnostics", 1)[1].split(
            "private static func waitForSnapshotProcess", 1
        )[0]

        self.assertIn("replacingOccurrences(of: secret, with: \"<redacted>\")", diagnostics)
        self.assertIn("combined.utf8.prefix(archiveDiagnosticByteLimit)", diagnostics)
        self.assertLess(
            diagnostics.index("replacingOccurrences(of: secret"),
            diagnostics.index("combined.utf8.prefix(archiveDiagnosticByteLimit)"),
        )

    def test_archive_timeout_and_view_model_operations_are_safely_classified(self):
        transport = (CORE / "OpenSSHTransport.swift").read_text(encoding="utf-8")
        view_model = (APP / "MonitorViewModel.swift").read_text(encoding="utf-8")
        package = (ROOT / "Package.swift").read_text(encoding="utf-8")
        view_model_tests = (
            ROOT / "Tests" / "HermesMonitorAppTests" / "MonitorViewModelTests.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("remote outcome is unknown", transport.lower())
        self.assertIn("isArchiveOutcomeUnknown", view_model)
        self.assertIn("canRetry: false", view_model)
        self.assertIn("guard !isRefreshing", view_model)
        self.assertIn('name: "HermesMonitorAppTests"', package)
        self.assertIn("testArchiveSerializesManualRefresh", view_model_tests)
        self.assertIn("testArchiveTimeoutReportsUnknownRemoteOutcome", view_model_tests)

    def test_compact_mode_has_persisted_separate_progress_and_liveness_contracts(self):
        presentation = (CORE / "TaskPresentation.swift").read_text(encoding="utf-8")
        preferences = (CORE / "TaskListPreferences.swift").read_text(encoding="utf-8")
        root = (APP / "MonitorRootView.swift").read_text(encoding="utf-8")
        task_list = (APP / "TaskListView.swift").read_text(encoding="utf-8")
        archive_control = (APP / "TaskArchiveControl.swift").read_text(encoding="utf-8")
        view_model = (APP / "MonitorViewModel.swift").read_text(encoding="utf-8")

        self.assertIn("childProgressPercent", presentation)
        self.assertIn("completedChildCount", presentation)
        self.assertIn("public var childCount: Int { children.count }", presentation)
        self.assertIn("public var totalCount: Int { children.count + 1 }", presentation)
        self.assertIn("TaskGroupLivenessState", presentation)
        self.assertIn('taskListMode = "HermesMonitor.taskListMode"', preferences)
        self.assertIn('collapsedGroupIDs = "HermesMonitor.collapsedGroupIDs"', preferences)
        self.assertIn("minimumPanelWidth = 360", preferences)
        self.assertIn("Use compact task list", root)
        self.assertIn("LIVE:", task_list)
        self.assertIn("No heartbeat recorded", task_list)
        self.assertIn("Remove from board", archive_control)
        self.assertIn("nothing is permanently deleted", archive_control)
        self.assertIn("Try Again", root)
        self.assertIn("Dismiss", root)
        self.assertIn("Removed from active board", view_model)
        self.assertIn("Task is no longer Done", view_model)

    def test_transient_log_errors_use_diagnostics_while_path_rejections_remain_warnings(self):
        synchronizer = (CORE / "RemoteSnapshotSynchronizer.swift").read_text(encoding="utf-8")
        transient_block = synchronizer.split(
            "catch let error where isTransientLogReadFailure(error)", 1
        )[1].split("} catch {", 1)[0]

        self.assertIn("RemoteSnapshotDiagnosticSink", synchronizer)
        self.assertIn("isTransientLogReadFailure", synchronizer)
        self.assertIn("failedLogFingerprints", synchronizer)
        self.assertNotIn("warnings.append", transient_block)
        self.assertIn('warnings.append("Could not refresh worker log for', synchronizer)
        self.assertIn('warnings.append("Rejected log path for', synchronizer)

    def test_compact_and_archive_copy_preserve_the_approved_accessibility_contract(self):
        task_list = (APP / "TaskListView.swift").read_text(encoding="utf-8")
        task_card = (APP / "TaskCardView.swift").read_text(encoding="utf-8")
        visual_style = (APP / "TaskVisualStyle.swift").read_text(encoding="utf-8")
        archive_control = (APP / "TaskArchiveControl.swift").read_text(encoding="utf-8")
        view_model = (APP / "MonitorViewModel.swift").read_text(encoding="utf-8")
        readme = (ROOT / "README.md").read_text(encoding="utf-8")

        self.assertIn("reconcileCollapsedGroups", task_list)
        self.assertIn("/\\(group.childCount) complete", task_list)
        self.assertIn("groupLivenessLabel", task_list)
        self.assertIn("No active run", task_list)
        self.assertIn("compactSymbolName", visual_style)
        self.assertIn("showsWaveform: false", task_list)
        self.assertIn("let showsWaveform: Bool", task_card)
        self.assertIn("Its runs, events, comments, result, and evidence remain preserved", archive_control)
        self.assertIn("nothing is permanently deleted", archive_control)
        self.assertIn("Removed from active board — archived on server.", view_model)
        self.assertIn("No task record was deleted.", view_model)
        self.assertIn("Task is no longer Done; it was not removed.", view_model)
        self.assertIn("bounded write-through", readme.lower())

    def test_expanded_group_keeps_legacy_all_task_progress_contract(self):
        task_list = (APP / "TaskListView.swift").read_text(encoding="utf-8")
        presentation = (CORE / "TaskPresentation.swift").read_text(encoding="utf-8")
        expanded_block = task_list.split("private func expandedGroup", 1)[1].split(
            "private func compactGroup", 1
        )[0]

        self.assertIn("\\(group.completedCount)/\\(group.totalCount) done", expanded_block)
        self.assertNotIn("group.childProgressPercent", expanded_block)
        self.assertIn("children.count + 1", presentation)
        self.assertIn("([parent] + children).filter", presentation)

    def test_compact_navigation_and_controls_cover_initial_deep_links_and_hit_targets(self):
        task_list = (APP / "TaskListView.swift").read_text(encoding="utf-8")
        root = (APP / "MonitorRootView.swift").read_text(encoding="utf-8")
        archive_control = (APP / "TaskArchiveControl.swift").read_text(encoding="utf-8")
        compact_task = task_list.split("private func compactTask", 1)[1].split(
            "private func card", 1
        )[0]

        self.assertIn("expandSelectedTask(selectedTaskID, in: groups)", task_list)
        self.assertIn(".id(item.id)", compact_task)
        self.assertIn(".onAppear", root)
        self.assertIn("scrollToSelectedTask", root)
        self.assertIn("accessibilityReduceMotion", root)
        self.assertIn("CompactTaskLayout.disclosureHitTarget", task_list)
        self.assertIn("CompactTaskLayout.disclosureHitTarget", archive_control)
        self.assertNotIn("compact ? 44 : 24", archive_control)
        mode_toggle = root.split("Button {\n                taskListModeRaw =", 1)[1].split(
            "Button {", 1
        )[0]
        self.assertIn("CompactTaskLayout.disclosureHitTarget", mode_toggle)
        compact_group = task_list.split("private func compactGroup", 1)[1].split(
            "private func compactTask", 1
        )[0]
        self.assertIn("ForEach(group.compactDrillDownTasks)", compact_group)
        self.assertNotIn("compactTask(group.parent)", compact_group)
        self.assertIn("Archive is unavailable while", archive_control)
        self.assertNotIn("read-only remote observer", root)


if __name__ == "__main__":
    unittest.main()
