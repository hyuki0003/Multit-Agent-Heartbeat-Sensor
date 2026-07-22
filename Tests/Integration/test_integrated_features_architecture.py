import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
CORE = ROOT / "Sources" / "HermesMonitorCore"
APP = ROOT / "Sources" / "HermesMonitorApp"


class IntegratedFeatureArchitectureTests(unittest.TestCase):
    def test_automatic_done_archive_preference_is_explicit_persisted_and_defaults_off(self):
        preferences = (CORE / "TaskListPreferences.swift").read_text(encoding="utf-8")
        settings = (APP / "MonitorSettingsView.swift").read_text(encoding="utf-8")

        self.assertIn("AutomaticDoneArchivePreference", preferences)
        self.assertIn('automaticallyRemoveDoneTasks = "HermesMonitor.automaticallyRemoveDoneTasks"', preferences)
        self.assertIn("guard defaults.object(forKey: automaticallyRemoveDoneTasks) != nil else", preferences)
        self.assertIn("return false", preferences)
        self.assertIn(
            "@AppStorage(AutomaticDoneArchivePreference.automaticallyRemoveDoneTasks)",
            settings,
        )
        self.assertIn("private var automaticallyRemoveDoneTasks = false", settings)
        self.assertIn('Toggle("Automatically remove Done tasks"', settings)

    def test_automatic_done_archive_is_wired_to_runtime_with_destructive_action_copy(self):
        app = (APP / "HermesMonitorApp.swift").read_text(encoding="utf-8")
        settings = (APP / "MonitorSettingsView.swift").read_text(encoding="utf-8")

        self.assertIn("automaticallyArchiveDoneTasks: {", app)
        self.assertIn("AutomaticDoneArchivePreference.load()", app)
        self.assertIn("Disabled by default", settings)
        self.assertIn("does not hard-delete it", settings)

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

    def test_active_board_projection_excludes_only_archived_and_is_called_before_grouping(self):
        presentation = (CORE / "TaskPresentation.swift").read_text(encoding="utf-8")
        task_list = (APP / "TaskListView.swift").read_text(encoding="utf-8")

        # Core exposes a projection that excludes only .archived; .done and every
        # other status are retained so archive failures stay inspectable.
        self.assertIn("public enum ActiveBoardProjection", presentation)
        self.assertIn(
            "public static func activeBoardTasks(from tasks: [CorrelatedTask]) -> [CorrelatedTask]",
            presentation,
        )
        projection_body = presentation.split(
            "public enum ActiveBoardProjection", 1
        )[1].split("public enum TaskGroupBuilder", 1)[0]
        self.assertIn(".archived", projection_body)
        self.assertIn("$0.task.status != .archived", projection_body)
        # Must NOT filter any other status.
        self.assertNotIn("$0.task.status != .done", projection_body)
        self.assertNotIn("$0.task.status != .ready", projection_body)
        self.assertNotIn("$0.task.status != .running", projection_body)
        self.assertNotIn("$0.task.status != .blocked", projection_body)
        self.assertNotIn("$0.task.status != .failed", projection_body)
        self.assertNotIn("$0.task.status != .todo", projection_body)

        # TaskListView applies the projection before TaskGroupBuilder, not on
        # snapshot ingestion or KanbanStore.
        self.assertIn(
            "let activeTasks = ActiveBoardProjection.activeBoardTasks(from: snapshot.tasks)",
            task_list,
        )
        grouping_block = task_list.split(
            "let activeTasks = ActiveBoardProjection.activeBoardTasks(from: snapshot.tasks)",
            1,
        )[1]
        self.assertIn("TaskGroupBuilder.groups", grouping_block)
        self.assertIn("tasks: activeTasks", grouping_block)
        # The raw snapshot.tasks must no longer be passed straight to grouping.
        self.assertNotIn("tasks: snapshot.tasks,", task_list)

    def test_active_board_projection_keeps_archived_parent_excluded_child_visible_as_standalone(self):
        presentation = (CORE / "TaskPresentation.swift").read_text(encoding="utf-8")
        task_list = (APP / "TaskListView.swift").read_text(encoding="utf-8")

        # The active-board projection operates only on CorrelatedTask rows, not on
        # links. TaskGroupBuilder still receives every active child, so a child
        # whose parent was archived remains visible as a standalone group root
        # because its parent is absent from the taskByID map (link parent pointer
        # cannot resolve) and TaskGroupBuilder already promotes unvisited tasks.
        self.assertIn(
            "public static func activeBoardTasks(from tasks: [CorrelatedTask]) -> [CorrelatedTask]",
            presentation,
        )
        self.assertIn("public static func groups(", presentation)
        # TaskListView must not filter links or KanbanStore/snapshot.
        self.assertNotIn("links: snapshot.kanban.links.filter", task_list)
        self.assertNotIn("ActiveBoardProjection.activeBoardTasks(from: snapshot.kanban.links", task_list)
        # Projection must live only at the presentation boundary (TaskListView and
        # MonitorRootView), not inside the view model or store/ingestion layer.
        view_model = (APP / "MonitorViewModel.swift").read_text(encoding="utf-8")
        self.assertNotIn("ActiveBoardProjection", view_model)

        # MonitorRootView must base its empty-state decision and summary counts on
        # the same projected active tasks, not raw snapshot.tasks, so an all-archived
        # board shows the empty state and the header counts match the list.
        root = (APP / "MonitorRootView.swift").read_text(encoding="utf-8")
        self.assertIn(
            "ActiveBoardProjection.activeBoardTasks(from: snapshot.tasks)",
            root,
        )
        root_summary = root.split("private func summary", 1)[1]
        self.assertIn("activeTasks.filter { $0.visualStatus == .running }.count", root_summary)
        self.assertIn("activeTasks.count) tasks", root_summary)
        self.assertNotIn("snapshot.tasks.filter { $0.visualStatus == .running }.count", root_summary)
        self.assertNotIn("snapshot.tasks.count) tasks", root_summary)

        # Required store/ingestion sources must exist before we read them; do not
        # silently skip a missing candidate (that would hide a real regression).
        required_sources = [
            CORE / "Stores.swift",
            CORE / "HermesMonitorClient.swift",
            CORE / "RemoteKanbanArchiving.swift",
            CORE / "RemoteSnapshotSynchronizer.swift",
        ]
        for source in required_sources:
            self.assertTrue(
                source.exists(),
                f"Required source missing: {source.name}",
            )
            self.assertNotIn(
                "ActiveBoardProjection",
                source.read_text(encoding="utf-8"),
                f"ActiveBoardProjection leaked into {source.name}",
            )


if __name__ == "__main__":
    unittest.main()
