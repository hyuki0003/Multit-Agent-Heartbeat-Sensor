import json
import os
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "Sources/HermesMonitorCore/Resources/TaskFamilyArchiveHelper.py"
HERMES_AGENT = Path("/home/dhlee/.hermes/hermes-agent")
PYTHON = HERMES_AGENT / "venv/bin/python"


@unittest.skipUnless(PYTHON.exists(), "Hermes Agent Python environment is required")
class TaskFamilyArchiveHelperIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.database = Path(self.temporary_directory.name) / "kanban.db"
        self.environment = os.environ.copy()
        self.environment.update(
            {
                "HERMES_KANBAN_DB": str(self.database),
                "HERMES_KANBAN_BOARD": "family-archive-helper-test",
                "PYTHONPATH": str(HERMES_AGENT),
            }
        )
        subprocess.run(
            [str(PYTHON), "-c", "from hermes_cli.kanban_db import connect; connect().close()"],
            env=self.environment,
            check=True,
            capture_output=True,
            text=True,
        )

    def tearDown(self):
        self.temporary_directory.cleanup()

    def create_task(self, key, status="done"):
        environment = self.environment.copy()
        environment["TASK_KEY"] = key
        result = subprocess.run(
            [
                str(PYTHON),
                "-c",
                "import os; from hermes_cli.kanban_db import connect, create_task; "
                "c=connect(); task_id=create_task(c,title=os.environ['TASK_KEY'],"
                "assignee='rune-implementer',created_by='test',"
                "idempotency_key=os.environ['TASK_KEY']); "
                "c.execute('UPDATE tasks SET status=? WHERE id=?', "
                "(os.environ['TASK_STATUS'], task_id)); c.commit(); print(task_id); c.close()",
            ],
            env={**environment, "TASK_STATUS": status},
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()

    def invoke(self, max_families=4, max_tasks=32):
        return subprocess.run(
            [str(PYTHON), str(HELPER)],
            input=json.dumps(
                {
                    "max_families": max_families,
                    "max_tasks": max_tasks,
                    "client_source": "hermes-monitor",
                }
            ),
            env=self.environment,
            capture_output=True,
            text=True,
        )

    def link(self, parent_id, child_id):
        environment = {
            **self.environment,
            "PARENT_ID": parent_id,
            "CHILD_ID": child_id,
        }
        subprocess.run(
            [
                str(PYTHON),
                "-c",
                "import os; from hermes_cli.kanban_db import connect, link_tasks; "
                "c=connect(); link_tasks(c, os.environ['PARENT_ID'], os.environ['CHILD_ID']); "
                "c.close()",
            ],
            env=environment,
            check=True,
            capture_output=True,
            text=True,
        )

    def archive_canonically(self, task_id):
        subprocess.run(
            [
                str(PYTHON),
                "-c",
                "import os; from hermes_cli.kanban_db import archive_task, connect; "
                "c=connect(); archive_task(c, os.environ['TASK_ID']); c.close()",
            ],
            env={**self.environment, "TASK_ID": task_id},
            check=True,
            capture_output=True,
            text=True,
        )

    def execute(self, sql, parameters=()):
        connection = sqlite3.connect(self.database)
        try:
            connection.execute(sql, parameters)
            connection.commit()
        finally:
            connection.close()

    def query(self, sql, parameters=()):
        connection = sqlite3.connect(self.database)
        try:
            return connection.execute(sql, parameters).fetchall()
        finally:
            connection.close()

    def logical_dump(self):
        connection = sqlite3.connect(self.database)
        try:
            return "\n".join(connection.iterdump())
        finally:
            connection.close()

    def add_comment(self, task_id, body):
        self.execute(
            "INSERT INTO task_comments(task_id, author, body, created_at) "
            "VALUES (?, 'test', ?, 1)",
            (task_id, body),
        )

    def test_archives_standalone_done_task_with_canonical_event_and_keeps_audit_rows(self):
        task_id = self.create_task("standalone-done")
        connection = sqlite3.connect(self.database)
        connection.execute(
            "INSERT INTO task_comments(task_id, author, body, created_at) "
            "VALUES (?, 'test', 'audit-comment', 1)",
            (task_id,),
        )
        connection.execute(
            "INSERT INTO task_events(task_id, kind, payload, created_at) "
            "VALUES (?, 'audit-before-archive', NULL, 1)",
            (task_id,),
        )
        connection.commit()
        connection.close()

        result = self.invoke()

        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["outcome"], "archived")
        self.assertEqual(receipt["archived_family_count"], 1)
        self.assertEqual(receipt["archived_task_count"], 1)
        self.assertEqual(receipt["archived_task_ids"], [task_id])
        self.assertFalse(receipt["bounded"])
        self.assertIsNone(receipt["reason"])
        self.assertEqual(self.query("SELECT status FROM tasks WHERE id=?", (task_id,)), [("archived",)])
        self.assertEqual(
            self.query("SELECT body FROM task_comments WHERE task_id=?", (task_id,)),
            [("audit-comment",)],
        )
        event_kinds = [
            row[0]
            for row in self.query(
                "SELECT kind FROM task_events WHERE task_id=? ORDER BY id", (task_id,)
            )
        ]
        self.assertIn("audit-before-archive", event_kinds)
        self.assertEqual(event_kinds[-1], "archived")

    def test_archives_linear_family_leaves_first_and_preserves_canonical_link(self):
        root_id = self.create_task("linear-root")
        child_id = self.create_task("linear-child")
        self.link(root_id, child_id)

        result = self.invoke()

        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["archived_family_count"], 1)
        self.assertEqual(receipt["archived_task_count"], 2)
        self.assertEqual(receipt["archived_task_ids"], [child_id, root_id])
        self.assertEqual(
            self.query("SELECT id, status FROM tasks ORDER BY id"),
            sorted([(root_id, "archived"), (child_id, "archived")]),
        )
        self.assertEqual(
            self.query("SELECT parent_id, child_id FROM task_links"),
            [(root_id, child_id)],
        )
        self.assertEqual(
            self.query(
                "SELECT task_id FROM task_events WHERE kind='archived' ORDER BY id"
            ),
            [(child_id,), (root_id,)],
        )

    def test_rejects_requested_work_above_documented_server_caps_without_writes(self):
        task_id = self.create_task("over-cap")

        result = self.invoke(max_families=5, max_tasks=33)

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(
            self.query("SELECT status FROM tasks WHERE id=?", (task_id,)),
            [("done",)],
        )
        self.assertEqual(
            self.query(
                "SELECT COUNT(*) FROM task_events WHERE task_id=? AND kind='archived'",
                (task_id,),
            ),
            [(0,)],
        )


    def test_archives_nested_diamond_family_in_reverse_topological_order(self):
        root_id = self.create_task("diamond-root")
        left_id = self.create_task("diamond-left")
        right_id = self.create_task("diamond-right")
        leaf_id = self.create_task("diamond-leaf")
        self.link(root_id, left_id)
        self.link(root_id, right_id)
        self.link(left_id, leaf_id)
        self.link(right_id, leaf_id)

        result = self.invoke()

        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["archived_family_count"], 1)
        self.assertEqual(receipt["archived_task_count"], 4)
        self.assertEqual(receipt["archived_task_ids"][0], leaf_id)
        self.assertEqual(receipt["archived_task_ids"][-1], root_id)
        self.assertEqual(
            set(receipt["archived_task_ids"]),
            {root_id, left_id, right_id, leaf_id},
        )

    def test_defers_any_family_with_an_active_root_or_descendant(self):
        done_root = self.create_task("done-root")
        running_child = self.create_task("running-child", status="running")
        running_root = self.create_task("running-root", status="running")
        done_child = self.create_task("done-child")
        self.link(done_root, running_child)
        self.link(running_root, done_child)

        result = self.invoke()

        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["outcome"], "noop")
        self.assertEqual(receipt["archived_task_count"], 0)
        self.assertEqual(receipt["deferred_family_count"], 2)
        self.assertEqual(
            self.query("SELECT COUNT(*) FROM tasks WHERE status='archived'"),
            [(0,)],
        )

    def test_archived_bridge_defers_done_ancestor_of_running_descendant_without_writes(self):
        done_root = self.create_task("archived-bridge-running-root")
        archived_bridge = self.create_task("archived-bridge-running-middle")
        running_child = self.create_task(
            "archived-bridge-running-child", status="running"
        )
        self.link(done_root, archived_bridge)
        self.link(archived_bridge, running_child)
        self.add_comment(done_root, "retain-running-bridge-comment")
        self.archive_canonically(archived_bridge)
        before = self.logical_dump()

        result = self.invoke()

        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["outcome"], "noop")
        self.assertEqual(receipt["archived_task_ids"], [])
        self.assertEqual(receipt["deferred_family_count"], 1)
        self.assertEqual(self.logical_dump(), before)

    def test_archived_bridge_shared_with_blocked_parent_defers_family_without_writes(self):
        done_parent = self.create_task("archived-shared-done-parent")
        blocked_parent = self.create_task(
            "archived-shared-blocked-parent", status="blocked"
        )
        archived_child = self.create_task("archived-shared-child")
        self.link(done_parent, archived_child)
        self.link(blocked_parent, archived_child)
        self.add_comment(archived_child, "retain-shared-bridge-comment")
        self.archive_canonically(archived_child)
        before = self.logical_dump()

        result = self.invoke()

        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["outcome"], "noop")
        self.assertEqual(receipt["archived_task_ids"], [])
        self.assertEqual(receipt["deferred_family_count"], 1)
        self.assertEqual(self.logical_dump(), before)

    def test_rejects_cycle_containing_archived_vertex_without_writes(self):
        done_task = self.create_task("archived-cycle-done")
        archived_task = self.create_task("archived-cycle-middle")
        self.link(done_task, archived_task)
        self.archive_canonically(archived_task)
        self.execute(
            "INSERT INTO task_links(parent_id, child_id) VALUES (?, ?)",
            (archived_task, done_task),
        )
        self.add_comment(archived_task, "retain-archived-cycle-comment")
        before = self.logical_dump()

        result = self.invoke()

        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["outcome"], "rejected")
        self.assertEqual(receipt["reason"], "malformed_graph")
        self.assertEqual(receipt["archived_task_ids"], [])
        self.assertEqual(self.logical_dump(), before)

    def test_archives_remaining_done_members_connected_through_archived_bridge(self):
        done_root = self.create_task("archived-done-bridge-root")
        archived_bridge = self.create_task("archived-done-bridge-middle")
        done_child = self.create_task("archived-done-bridge-child")
        self.link(done_root, archived_bridge)
        self.link(archived_bridge, done_child)
        self.add_comment(done_root, "retain-done-bridge-root-comment")
        self.add_comment(archived_bridge, "retain-done-bridge-middle-comment")
        self.add_comment(done_child, "retain-done-bridge-child-comment")
        self.archive_canonically(archived_bridge)
        links_before = self.query(
            "SELECT parent_id, child_id FROM task_links ORDER BY parent_id, child_id"
        )
        comments_before = self.query(
            "SELECT task_id, author, body, created_at FROM task_comments ORDER BY id"
        )
        events_before = self.query(
            "SELECT id, task_id, kind, payload, created_at FROM task_events ORDER BY id"
        )

        result = self.invoke()

        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["outcome"], "archived")
        self.assertEqual(receipt["archived_family_count"], 1)
        self.assertEqual(receipt["archived_task_ids"], [done_child, done_root])
        self.assertEqual(
            self.query(
                "SELECT status FROM tasks WHERE id IN (?, ?, ?) ORDER BY id",
                (done_root, archived_bridge, done_child),
            ),
            [("archived",), ("archived",), ("archived",)],
        )
        self.assertEqual(
            self.query(
                "SELECT parent_id, child_id FROM task_links ORDER BY parent_id, child_id"
            ),
            links_before,
        )
        self.assertEqual(
            self.query(
                "SELECT task_id, author, body, created_at FROM task_comments ORDER BY id"
            ),
            comments_before,
        )
        events_after = self.query(
            "SELECT id, task_id, kind, payload, created_at FROM task_events ORDER BY id"
        )
        self.assertEqual(events_after[: len(events_before)], events_before)
        self.assertEqual(
            [(row[1], row[2]) for row in events_after[len(events_before) :]],
            [(done_child, "archived"), (done_root, "archived")],
        )

    def test_partial_prior_archive_retries_remaining_family_member(self):
        root_id = self.create_task("partial-root")
        child_id = self.create_task("partial-child")
        self.link(root_id, child_id)
        self.archive_canonically(child_id)

        result = self.invoke()

        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["archived_task_ids"], [root_id])
        self.assertEqual(
            self.query("SELECT status FROM tasks WHERE id IN (?, ?) ORDER BY id", (root_id, child_id)),
            [("archived",), ("archived",)],
        )
        self.assertEqual(
            self.query("SELECT parent_id, child_id FROM task_links"),
            [(root_id, child_id)],
        )

    def test_shared_child_waits_for_every_active_root(self):
        done_root = self.create_task("shared-done-root")
        active_root = self.create_task("shared-active-root", status="blocked")
        child_id = self.create_task("shared-child")
        self.link(done_root, child_id)
        self.link(active_root, child_id)

        result = self.invoke()

        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["outcome"], "noop")
        self.assertEqual(receipt["archived_task_ids"], [])
        self.assertEqual(
            self.query("SELECT status FROM tasks WHERE id=?", (child_id,)),
            [("done",)],
        )

    def test_rejects_cycle_without_any_archive_write(self):
        first_id = self.create_task("cycle-first")
        second_id = self.create_task("cycle-second")
        self.execute(
            "INSERT INTO task_links(parent_id, child_id) VALUES (?, ?), (?, ?)",
            (first_id, second_id, second_id, first_id),
        )

        result = self.invoke()

        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["outcome"], "rejected")
        self.assertEqual(receipt["reason"], "malformed_graph")
        self.assertEqual(
            self.query("SELECT COUNT(*) FROM tasks WHERE status='archived'"),
            [(0,)],
        )
        self.assertEqual(
            self.query("SELECT COUNT(*) FROM task_events WHERE kind='archived'"),
            [(0,)],
        )

    def test_authoritative_status_change_before_request_defers_stale_done_candidate(self):
        task_id = self.create_task("stale-done")
        self.execute("UPDATE tasks SET status='ready' WHERE id=?", (task_id,))

        result = self.invoke()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["archived_task_ids"], [])
        self.assertEqual(
            self.query("SELECT status FROM tasks WHERE id=?", (task_id,)),
            [("ready",)],
        )

    def test_caps_selected_families_and_tasks_per_request(self):
        task_ids = [self.create_task(f"bounded-{index}") for index in range(3)]

        result = self.invoke(max_families=2, max_tasks=2)

        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["archived_family_count"], 2)
        self.assertEqual(receipt["archived_task_count"], 2)
        self.assertTrue(receipt["bounded"])
        self.assertEqual(receipt["deferred_family_count"], 1)
        self.assertEqual(
            self.query("SELECT COUNT(*) FROM tasks WHERE status='done'"),
            [(1,)],
        )
        self.assertEqual(set(receipt["archived_task_ids"]).issubset(set(task_ids)), True)

    def test_atomic_interruption_rolls_back_then_retry_converges(self):
        root_id = self.create_task("retry-root")
        child_id = self.create_task("retry-child")
        self.link(root_id, child_id)
        self.execute(
            "CREATE TRIGGER interrupt_root_archive BEFORE UPDATE OF status ON tasks "
            "WHEN OLD.id = '%s' AND NEW.status = 'archived' "
            "BEGIN SELECT RAISE(ABORT, 'injected interruption'); END" % root_id
        )

        interrupted = self.invoke()

        self.assertNotEqual(interrupted.returncode, 0)
        self.assertEqual(
            self.query("SELECT COUNT(*) FROM tasks WHERE status='archived'"),
            [(0,)],
        )
        self.assertEqual(
            self.query("SELECT COUNT(*) FROM task_events WHERE kind='archived'"),
            [(0,)],
        )
        self.execute("DROP TRIGGER interrupt_root_archive")

        retried = self.invoke()

        self.assertEqual(retried.returncode, 0, retried.stderr)
        self.assertEqual(
            json.loads(retried.stdout)["archived_task_ids"],
            [child_id, root_id],
        )

    def test_helper_contains_no_hard_delete_or_retention_pruning_sql(self):
        source = HELPER.read_text(encoding="utf-8").upper()

        self.assertNotIn("DELETE FROM", source)
        self.assertNotIn("VACUUM", source)
        self.assertNotIn("DROP TABLE", source)


if __name__ == "__main__":
    unittest.main()
