import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "Sources/HermesMonitorCore/Resources/TaskInstructionHelper.py"
HERMES_AGENT = Path("/home/dhlee/.hermes/hermes-agent")
PYTHON = HERMES_AGENT / "venv/bin/python"


@unittest.skipUnless(PYTHON.exists(), "Hermes Agent Python environment is required")
class TaskInstructionHelperIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.database = Path(self.temporary_directory.name) / "kanban.db"
        self.environment = os.environ.copy()
        self.environment.update(
            {
                "HERMES_KANBAN_DB": str(self.database),
                "HERMES_KANBAN_BOARD": "instruction-helper-test",
                "PYTHONPATH": str(HERMES_AGENT),
            }
        )
        seed = (
            "from hermes_cli.kanban_db import connect, create_task; "
            "c=connect(); "
            "create_task(c,title='Target',assignee='rune-implementer',created_by='test',"
            "idempotency_key='instruction-target'); "
            "c.close()"
        )
        subprocess.run(
            [str(PYTHON), "-c", seed],
            env=self.environment,
            check=True,
            capture_output=True,
            text=True,
        )
        query = (
            "from hermes_cli.kanban_db import connect; "
            "c=connect(); print(c.execute(\"SELECT id FROM tasks WHERE idempotency_key='instruction-target'\").fetchone()[0])"
        )
        result = subprocess.run(
            [str(PYTHON), "-c", query],
            env=self.environment,
            check=True,
            capture_output=True,
            text=True,
        )
        self.target_task_id = result.stdout.strip()

    def tearDown(self):
        self.temporary_directory.cleanup()

    def invoke(self, payload):
        return subprocess.run(
            [str(PYTHON), str(HELPER)],
            input=json.dumps(payload, ensure_ascii=False),
            env=self.environment,
            capture_output=True,
            text=True,
        )

    def create_target(self, idempotency_key):
        environment = self.environment.copy()
        environment["IDEMPOTENCY_KEY"] = idempotency_key
        result = subprocess.run(
            [
                str(PYTHON),
                "-c",
                "import os; from hermes_cli.kanban_db import connect, create_task; "
                "c=connect(); print(create_task(c,title='Other Target',"
                "assignee='rune-implementer',created_by='test',"
                "idempotency_key=os.environ['IDEMPOTENCY_KEY'])); c.close()",
            ],
            env=environment,
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()

    def seed_run(
        self,
        status,
        task_id=None,
        make_current=True,
        *,
        outcome=None,
        started_at=1,
    ):
        target_task_id = task_id or self.target_task_id
        connection = sqlite3.connect(self.database)
        cursor = connection.execute(
            "INSERT INTO task_runs"
            "(task_id, profile, status, started_at, ended_at, outcome) "
            "VALUES (?, 'rune-implementer', ?, ?, ?, ?)",
            (
                target_task_id,
                status,
                started_at,
                None if status == "running" else started_at + 1,
                outcome,
            ),
        )
        run_id = cursor.lastrowid
        if make_current:
            connection.execute(
                "UPDATE tasks SET status='running', current_run_id=? WHERE id=?",
                (run_id, target_task_id),
            )
        connection.commit()
        connection.close()
        return run_id

    def set_target_state(self, status, current_run_id=None):
        connection = sqlite3.connect(self.database)
        connection.execute(
            "UPDATE tasks SET status=?, current_run_id=? WHERE id=?",
            (status, current_run_id, self.target_task_id),
        )
        connection.commit()
        connection.close()

    def seed_existing_comment(self, instruction_id, message):
        connection = sqlite3.connect(self.database)
        cursor = connection.execute(
            "INSERT INTO task_comments(task_id, author, body, created_at) "
            "VALUES (?, 'user', ?, 1)",
            (
                self.target_task_id,
                f"{message}\n\n<!-- hermes-monitor-instruction:{instruction_id} -->",
            ),
        )
        comment_id = cursor.lastrowid
        connection.commit()
        connection.close()
        return comment_id

    def invoke_after_run_transition_at_comment_write(self, payload, transition_sql=None):
        harness = r"""
import importlib.util
import os
import sqlite3

spec = importlib.util.spec_from_file_location("task_instruction_helper", os.environ["HELPER_PATH"])
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
original = helper.add_comment

def transition_then_add_comment(conn, task_id, author, body):
    was_in_transaction = conn.in_transaction
    if os.environ.get("TRANSITION_SQL"):
        for statement in os.environ["TRANSITION_SQL"].split(";"):
            if statement.strip():
                conn.execute(statement)
    else:
        conn.execute(
            "UPDATE task_runs SET status='done', ended_at=2 WHERE id=?",
            (int(os.environ["RUN_ID"]),),
        )
        conn.execute(
            "UPDATE tasks SET current_run_id=NULL WHERE id=?",
            (os.environ["TARGET_TASK_ID"],),
        )
    if not was_in_transaction:
        conn.commit()
    return original(conn, task_id, author, body)

helper.add_comment = transition_then_add_comment
raise SystemExit(helper.main())
"""
        environment = self.environment.copy()
        environment.update(
            {
                "HELPER_PATH": str(HELPER),
                "RUN_ID": str(payload["run_id"]),
                "TARGET_TASK_ID": payload["task_id"],
            }
        )
        if transition_sql is not None:
            environment["TRANSITION_SQL"] = transition_sql
        return subprocess.run(
            [str(PYTHON), "-c", harness],
            input=json.dumps(payload, ensure_ascii=False),
            env=environment,
            capture_output=True,
            text=True,
        )

    def invoke_after_run_transition_at_envelope_write(self, payload, transition_sql=None):
        harness = r"""
import importlib.util
import os
import sqlite3

spec = importlib.util.spec_from_file_location("task_instruction_helper", os.environ["HELPER_PATH"])
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
original = helper.create_task

def transition_then_create_task(conn, **kwargs):
    transition = sqlite3.connect(os.environ["HERMES_KANBAN_DB"])
    if os.environ.get("TRANSITION_SQL"):
        transition.executescript(os.environ["TRANSITION_SQL"])
    else:
        transition.execute(
            "UPDATE task_runs SET status='done', ended_at=2 WHERE id=?",
            (int(os.environ["RUN_ID"]),),
        )
        transition.execute(
            "UPDATE tasks SET current_run_id=NULL WHERE id=?",
            (os.environ["TARGET_TASK_ID"],),
        )
    transition.commit()
    transition.close()
    return original(conn, **kwargs)

helper.create_task = transition_then_create_task
raise SystemExit(helper.main())
"""
        environment = self.environment.copy()
        environment.update(
            {
                "HELPER_PATH": str(HELPER),
                "RUN_ID": str(payload["run_id"]),
                "TARGET_TASK_ID": payload["task_id"],
            }
        )
        if transition_sql is not None:
            environment["TRANSITION_SQL"] = transition_sql
        return subprocess.run(
            [str(PYTHON), "-c", harness],
            input=json.dumps(payload, ensure_ascii=False),
            env=environment,
            capture_output=True,
            text=True,
        )

    def invoke_after_fresh_comment_at_envelope_write(self, payload, transition):
        harness = r"""
import importlib.util
import os

spec = importlib.util.spec_from_file_location("task_instruction_helper", os.environ["HELPER_PATH"])
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
original = helper.create_task

def transition_then_create_task(conn, **kwargs):
    was_in_transaction = conn.in_transaction
    if os.environ["TRANSITION"] == "finish_running":
        conn.execute(
            "UPDATE task_runs SET status='done', outcome='completed', ended_at=2 WHERE id=?",
            (int(os.environ["RUN_ID"]),),
        )
        conn.execute(
            "UPDATE tasks SET status='done', current_run_id=NULL WHERE id=?",
            (os.environ["TARGET_TASK_ID"],),
        )
    elif os.environ["TRANSITION"] == "insert_newer_blocked":
        conn.execute(
            "INSERT INTO task_runs"
            "(task_id, profile, status, started_at, ended_at, outcome) "
            "VALUES (?, 'rune-implementer', 'blocked', 3, 4, 'blocked')",
            (os.environ["TARGET_TASK_ID"],),
        )
    else:
        raise AssertionError("unknown transition")
    if not was_in_transaction:
        conn.commit()
    return original(conn, **kwargs)

helper.create_task = transition_then_create_task
raise SystemExit(helper.main())
"""
        environment = self.environment.copy()
        environment.update(
            {
                "HELPER_PATH": str(HELPER),
                "RUN_ID": str(payload["run_id"]),
                "TARGET_TASK_ID": payload["task_id"],
                "TRANSITION": transition,
            }
        )
        return subprocess.run(
            [str(PYTHON), "-c", harness],
            input=json.dumps(payload, ensure_ascii=False),
            env=environment,
            capture_output=True,
            text=True,
        )

    def invoke_concurrently_after_lookup(self, payload, count=8):
        barrier = Path(self.temporary_directory.name) / "lookup-barrier"
        barrier.mkdir()
        harness = r"""
import importlib.util
import os
import time
from pathlib import Path

spec = importlib.util.spec_from_file_location("task_instruction_helper", os.environ["HELPER_PATH"])
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
original = helper._existing_envelope
barrier = Path(os.environ["LOOKUP_BARRIER"])
expected = int(os.environ["LOOKUP_BARRIER_COUNT"])

def synchronized_lookup(conn, instruction_id):
    result = original(conn, instruction_id)
    (barrier / str(os.getpid())).touch()
    deadline = time.monotonic() + 0.5
    while len(list(barrier.iterdir())) < expected and time.monotonic() < deadline:
        time.sleep(0.005)
    return result

helper._existing_envelope = synchronized_lookup
raise SystemExit(helper.main())
"""
        environment = self.environment.copy()
        environment.update(
            {
                "HELPER_PATH": str(HELPER),
                "LOOKUP_BARRIER": str(barrier),
                "LOOKUP_BARRIER_COUNT": str(count),
            }
        )
        encoded = json.dumps(payload, ensure_ascii=False)
        processes = [
            subprocess.Popen(
                [str(PYTHON), "-c", harness],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                text=True,
            )
            for _ in range(count)
        ]
        for process in processes:
            stdin = process.stdin
            assert stdin is not None
            stdin.write(encoded)
            stdin.close()
        results = []
        for process in processes:
            returncode = process.wait(timeout=15)
            stdout = process.stdout
            stderr = process.stderr
            assert stdout is not None
            assert stderr is not None
            results.append((returncode, stdout.read(), stderr.read()))
            stdout.close()
            stderr.close()
        return results

    def query_database(self):
        query = """
import json
import os
from hermes_cli.kanban_db import connect
c = connect()
comments = [dict(row) for row in c.execute(
    "SELECT id, task_id, author, body FROM task_comments ORDER BY id"
).fetchall()]
envelopes = [dict(row) for row in c.execute(
    "SELECT id, title, body, assignee, workspace_kind, workspace_path, "
    "max_runtime_seconds, idempotency_key FROM tasks WHERE idempotency_key LIKE 'hermes-monitor:%'"
).fetchall()]
events = [dict(row) for row in c.execute(
    "SELECT task_id, kind FROM task_events "
    "WHERE (task_id = ? AND kind = 'commented') OR "
    "(task_id IN (SELECT id FROM tasks WHERE idempotency_key LIKE 'hermes-monitor:%') "
    "AND kind = 'created') ORDER BY id",
    (os.environ["TARGET_TASK_ID"],),
).fetchall()]
print(json.dumps(
    {"comments": comments, "envelopes": envelopes, "events": events},
    ensure_ascii=False,
))
"""
        environment = self.environment.copy()
        environment["TARGET_TASK_ID"] = self.target_task_id
        result = subprocess.run(
            [str(PYTHON), "-c", query],
            env=environment,
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(result.stdout)

    def test_retry_is_idempotent_and_creates_canonical_comment_then_astra_envelope(self):
        instruction_id = "11111111-2222-3333-4444-555555555555"
        message = "옵션 B로 진행하고 [ASTRA_REPLY_KO] 형식으로 보고해 주세요."
        payload = {
            "instruction_id": instruction_id,
            "task_id": self.target_task_id,
            "message": message,
            "run_id": None,
            "selected_option_id": "B",
            "client_source": "hermes-monitor",
        }

        first = self.invoke(payload)
        second = self.invoke(payload)

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        first_receipt = json.loads(first.stdout)
        second_receipt = json.loads(second.stdout)
        self.assertEqual(
            set(first_receipt),
            {
                "accepted",
                "duplicate",
                "instruction_id",
                "source_comment_id",
                "envelope_task_id",
            },
        )
        self.assertEqual(first_receipt["instruction_id"], instruction_id)
        self.assertEqual(second_receipt["instruction_id"], instruction_id)
        self.assertTrue(first_receipt["accepted"])
        self.assertFalse(first_receipt["duplicate"])
        self.assertTrue(second_receipt["accepted"])
        self.assertTrue(second_receipt["duplicate"])
        self.assertEqual(first_receipt["source_comment_id"], second_receipt["source_comment_id"])
        self.assertEqual(first_receipt["envelope_task_id"], second_receipt["envelope_task_id"])

        database = self.query_database()
        self.assertEqual(len(database["comments"]), 1)
        self.assertEqual(len(database["envelopes"]), 1)
        comment = database["comments"][0]
        envelope = database["envelopes"][0]
        self.assertEqual(comment["task_id"], self.target_task_id)
        self.assertEqual(comment["author"], "user")
        self.assertTrue(comment["body"].startswith(message))
        self.assertIn(f"<!-- hermes-monitor-instruction:{instruction_id} -->", comment["body"])
        self.assertEqual(envelope["assignee"], "astra")
        self.assertEqual(envelope["workspace_kind"], "dir")
        self.assertEqual(envelope["workspace_path"], "/home/dhlee/projects/hermes-monitor-macos")
        self.assertEqual(envelope["max_runtime_seconds"], 900)
        self.assertEqual(envelope["idempotency_key"], f"hermes-monitor:{instruction_id}")
        self.assertIn(f"Source comment ID: {comment['id']}", envelope["body"])
        self.assertIn("Client source: hermes-monitor", envelope["body"])
        self.assertIn("<BEGIN_UNTRUSTED_USER_INSTRUCTION>", envelope["body"])
        self.assertIn(message, envelope["body"])
        self.assertIn("<END_UNTRUSTED_USER_INSTRUCTION>", envelope["body"])
        self.assertIn("[ASTRA_REPLY_KO]", envelope["body"])
        self.assertIn("research-team-governance", envelope["body"])
        self.assertEqual(
            database["events"],
            [
                {"task_id": self.target_task_id, "kind": "commented"},
                {"task_id": envelope["id"], "kind": "created"},
            ],
        )

    def test_concurrent_same_instruction_is_exactly_once_with_identical_receipts(self):
        instruction_id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        payload = {
            "instruction_id": instruction_id,
            "task_id": self.target_task_id,
            "message": "동일한 지시는 동시에 재시도되어도 한 번만 기록되어야 합니다.",
            "run_id": None,
            "selected_option_id": "A",
            "client_source": "hermes-monitor",
        }

        results = self.invoke_concurrently_after_lookup(payload)

        self.assertTrue(all(code == 0 for code, _, _ in results), results)
        receipts = [json.loads(stdout) for _, stdout, _ in results]
        self.assertEqual({receipt["instruction_id"] for receipt in receipts}, {instruction_id})
        self.assertEqual(len({receipt["source_comment_id"] for receipt in receipts}), 1)
        self.assertEqual(len({receipt["envelope_task_id"] for receipt in receipts}), 1)
        self.assertEqual(sum(not receipt["duplicate"] for receipt in receipts), 1)
        database = self.query_database()
        self.assertEqual(len(database["comments"]), 1)
        self.assertEqual(len(database["envelopes"]), 1)

    def test_archived_target_is_rejected_without_writes(self):
        environment = self.environment.copy()
        environment["TARGET_TASK_ID"] = self.target_task_id
        subprocess.run(
            [
                str(PYTHON),
                "-c",
                "import os; from hermes_cli.kanban_db import connect; "
                "c=connect(); c.execute('UPDATE tasks SET status=\"archived\" WHERE id=?', "
                "(os.environ['TARGET_TASK_ID'],)); c.commit(); c.close()",
            ],
            env=environment,
            check=True,
            capture_output=True,
            text=True,
        )
        result = self.invoke(
            {
                "instruction_id": "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff",
                "task_id": self.target_task_id,
                "message": "보관된 작업에는 기록되면 안 됩니다.",
                "run_id": None,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("target_not_actionable", result.stderr)
        self.assertNotIn("보관된 작업", result.stdout + result.stderr)
        database = self.query_database()
        self.assertEqual(database["comments"], [])
        self.assertEqual(database["envelopes"], [])

    def test_run_must_exist_and_belong_to_target(self):
        result = self.invoke(
            {
                "instruction_id": "cccccccc-dddd-4eee-8fff-aaaaaaaaaaaa",
                "task_id": self.target_task_id,
                "message": "존재하지 않는 실행에는 결합되면 안 됩니다.",
                "run_id": 999999999,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid_run_binding", result.stderr)
        self.assertNotIn("존재하지 않는 실행", result.stdout + result.stderr)
        database = self.query_database()
        self.assertEqual(database["comments"], [])
        self.assertEqual(database["envelopes"], [])

    def test_current_running_run_is_accepted(self):
        run_id = self.seed_run("running")
        result = self.invoke(
            {
                "instruction_id": "20000000-0000-4000-8000-000000000001",
                "task_id": self.target_task_id,
                "message": "현재 실행에 결합된 지시는 기록되어야 합니다.",
                "run_id": run_id,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            }
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        database = self.query_database()
        self.assertEqual(len(database["comments"]), 1)
        self.assertEqual(len(database["envelopes"]), 1)
        self.assertIn(f"Relevant run ID: {run_id}", database["envelopes"][0]["body"])

    def test_latest_authoritative_blocked_run_is_accepted(self):
        self.seed_run(
            "blocked",
            make_current=False,
            outcome="blocked",
            started_at=1,
        )
        latest_run_id = self.seed_run(
            "blocked",
            make_current=False,
            outcome="blocked",
            started_at=3,
        )
        self.set_target_state("blocked")

        result = self.invoke(
            {
                "instruction_id": "21000000-0000-4000-8000-000000000001",
                "task_id": self.target_task_id,
                "message": "가장 최근 차단 실행에는 지시를 기록해야 합니다.",
                "run_id": latest_run_id,
                "selected_option_id": "A",
                "client_source": "hermes-monitor",
            }
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        database = self.query_database()
        self.assertEqual(len(database["comments"]), 1)
        self.assertEqual(len(database["envelopes"]), 1)
        self.assertIn(
            f"Relevant run ID: {latest_run_id}",
            database["envelopes"][0]["body"],
        )

    def test_older_blocked_run_is_rejected_when_a_newer_run_exists(self):
        older_run_id = self.seed_run(
            "blocked",
            make_current=False,
            outcome="blocked",
            started_at=1,
        )
        self.seed_run(
            "blocked",
            make_current=False,
            outcome="blocked",
            started_at=3,
        )
        self.set_target_state("blocked")

        result = self.invoke(
            {
                "instruction_id": "22000000-0000-4000-8000-000000000001",
                "task_id": self.target_task_id,
                "message": "이전 차단 실행에는 기록되면 안 됩니다.",
                "run_id": older_run_id,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid_run_binding", result.stderr)
        database = self.query_database()
        self.assertEqual(database["comments"], [])
        self.assertEqual(database["envelopes"], [])

    def test_todo_and_ready_targets_accept_only_requests_without_a_run(self):
        for index, status in enumerate(("todo", "ready"), start=1):
            with self.subTest(status=status):
                self.set_target_state(status)
                result = self.invoke(
                    {
                        "instruction_id": f"23000000-0000-4000-8000-{index:012d}",
                        "task_id": self.target_task_id,
                        "message": f"{status} 작업에는 실행 없이 기록합니다.",
                        "run_id": None,
                        "selected_option_id": None,
                        "client_source": "hermes-monitor",
                    }
                )

                self.assertEqual(result.returncode, 0, result.stderr)
                database = self.query_database()
                self.assertEqual(len(database["comments"]), index)
                self.assertEqual(len(database["envelopes"]), index)

    def test_pending_target_with_run_history_accepts_explicit_null_binding(self):
        self.seed_run(
            "done",
            make_current=False,
            outcome="completed",
            started_at=10,
        )
        self.set_target_state("ready")

        result = self.invoke(
            {
                "instruction_id": "23500000-0000-4000-8000-000000000001",
                "task_id": self.target_task_id,
                "message": "실행 이력이 있어도 대기 작업에는 실행을 결합하지 않습니다.",
                "run_id": None,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            }
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        database = self.query_database()
        self.assertEqual(len(database["comments"]), 1)
        self.assertEqual(len(database["envelopes"]), 1)
        self.assertIn("Relevant run ID: none", database["envelopes"][0]["body"])

    def test_todo_and_ready_targets_reject_a_supplied_run_without_writes(self):
        run_id = self.seed_run("running", make_current=False)
        for index, status in enumerate(("todo", "ready"), start=1):
            with self.subTest(status=status):
                self.set_target_state(status)
                result = self.invoke(
                    {
                        "instruction_id": f"24000000-0000-4000-8000-{index:012d}",
                        "task_id": self.target_task_id,
                        "message": f"{status} 작업에는 실행을 결합하면 안 됩니다.",
                        "run_id": run_id,
                        "selected_option_id": None,
                        "client_source": "hermes-monitor",
                    }
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("invalid_run_binding", result.stderr)
                database = self.query_database()
                self.assertEqual(database["comments"], [])
                self.assertEqual(database["envelopes"], [])

    def test_running_target_rejects_a_missing_run_without_writes(self):
        self.seed_run("running")
        result = self.invoke(
            {
                "instruction_id": "24100000-0000-4000-8000-000000000001",
                "task_id": self.target_task_id,
                "message": "실행 중인 작업에는 실행 결합이 필요합니다.",
                "run_id": None,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid_run_binding", result.stderr)
        database = self.query_database()
        self.assertEqual(database["comments"], [])
        self.assertEqual(database["envelopes"], [])

    def test_blocked_target_rejects_a_missing_run_without_writes(self):
        self.seed_run(
            "blocked",
            make_current=False,
            outcome="blocked",
        )
        self.set_target_state("blocked")
        result = self.invoke(
            {
                "instruction_id": "24200000-0000-4000-8000-000000000001",
                "task_id": self.target_task_id,
                "message": "차단된 작업에도 권위 있는 실행 결합이 필요합니다.",
                "run_id": None,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid_run_binding", result.stderr)
        database = self.query_database()
        self.assertEqual(database["comments"], [])
        self.assertEqual(database["envelopes"], [])

    def test_blocked_to_ready_at_comment_boundary_is_rejected_without_writes(self):
        run_id = self.seed_run(
            "blocked",
            make_current=False,
            outcome="blocked",
        )
        self.set_target_state("blocked")
        result = self.invoke_after_run_transition_at_comment_write(
            {
                "instruction_id": "25000000-0000-4000-8000-000000000001",
                "task_id": self.target_task_id,
                "message": "차단 해제 경계에서는 기록되면 안 됩니다.",
                "run_id": run_id,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            },
            f"UPDATE tasks SET status='ready', current_run_id=NULL "
            f"WHERE id='{self.target_task_id}';",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid_run_binding", result.stderr)
        database = self.query_database()
        self.assertEqual(database["comments"], [])
        self.assertEqual(database["envelopes"], [])

    def test_blocked_to_running_at_comment_boundary_is_rejected_without_writes(self):
        run_id = self.seed_run(
            "blocked",
            make_current=False,
            outcome="blocked",
        )
        self.set_target_state("blocked")
        result = self.invoke_after_run_transition_at_comment_write(
            {
                "instruction_id": "26000000-0000-4000-8000-000000000001",
                "task_id": self.target_task_id,
                "message": "재개된 실행 경계에서는 기존 요청을 기록하면 안 됩니다.",
                "run_id": run_id,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            },
            f"UPDATE task_runs SET status='running', outcome=NULL, ended_at=NULL "
            f"WHERE id={run_id}; "
            f"UPDATE tasks SET status='running', current_run_id={run_id} "
            f"WHERE id='{self.target_task_id}';",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid_run_binding", result.stderr)
        database = self.query_database()
        self.assertEqual(database["comments"], [])
        self.assertEqual(database["envelopes"], [])

    def test_blocked_to_done_at_comment_boundary_is_rejected_without_writes(self):
        run_id = self.seed_run(
            "blocked",
            make_current=False,
            outcome="blocked",
        )
        self.set_target_state("blocked")
        result = self.invoke_after_run_transition_at_comment_write(
            {
                "instruction_id": "27000000-0000-4000-8000-000000000001",
                "task_id": self.target_task_id,
                "message": "완료된 작업 경계에서는 기록되면 안 됩니다.",
                "run_id": run_id,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            },
            f"UPDATE tasks SET status='done', current_run_id=NULL "
            f"WHERE id='{self.target_task_id}';",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("target_not_actionable", result.stderr)
        database = self.query_database()
        self.assertEqual(database["comments"], [])
        self.assertEqual(database["envelopes"], [])

    def test_running_to_blocked_at_comment_boundary_is_rejected_without_writes(self):
        run_id = self.seed_run("running")
        result = self.invoke_after_run_transition_at_comment_write(
            {
                "instruction_id": "28000000-0000-4000-8000-000000000001",
                "task_id": self.target_task_id,
                "message": "실행이 차단된 경계에서는 기존 요청을 기록하면 안 됩니다.",
                "run_id": run_id,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            },
            f"UPDATE task_runs SET status='blocked', outcome='blocked', ended_at=2 "
            f"WHERE id={run_id}; "
            f"UPDATE tasks SET status='blocked', current_run_id=NULL "
            f"WHERE id='{self.target_task_id}';",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid_run_binding", result.stderr)
        database = self.query_database()
        self.assertEqual(database["comments"], [])
        self.assertEqual(database["envelopes"], [])

    def test_fresh_running_transition_at_envelope_boundary_rolls_back_both_writes(self):
        run_id = self.seed_run("running")
        result = self.invoke_after_fresh_comment_at_envelope_write(
            {
                "instruction_id": "28500000-0000-4000-8000-000000000001",
                "task_id": self.target_task_id,
                "message": "새 요청의 봉투 경계에서 종료되면 부분 댓글을 남기면 안 됩니다.",
                "run_id": run_id,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            },
            "finish_running",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("target_not_actionable", result.stderr)
        database = self.query_database()
        self.assertEqual(database["comments"], [])
        self.assertEqual(database["envelopes"], [])
        self.assertEqual(database["events"], [])

    def test_fresh_newer_blocked_run_at_envelope_boundary_rolls_back_both_writes(self):
        run_id = self.seed_run(
            "blocked",
            make_current=False,
            outcome="blocked",
        )
        self.set_target_state("blocked")
        result = self.invoke_after_fresh_comment_at_envelope_write(
            {
                "instruction_id": "28600000-0000-4000-8000-000000000001",
                "task_id": self.target_task_id,
                "message": "새 요청의 봉투 경계에 최신 실행이 생기면 부분 댓글을 남기면 안 됩니다.",
                "run_id": run_id,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            },
            "insert_newer_blocked",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid_run_binding", result.stderr)
        database = self.query_database()
        self.assertEqual(database["comments"], [])
        self.assertEqual(database["envelopes"], [])
        self.assertEqual(database["events"], [])

    def test_blocked_to_running_at_envelope_boundary_rejects_recovery(self):
        instruction_id = "29000000-0000-4000-8000-000000000001"
        message = "복구 중 재개된 실행에는 기존 요청을 기록하면 안 됩니다."
        run_id = self.seed_run(
            "blocked",
            make_current=False,
            outcome="blocked",
        )
        self.set_target_state("blocked")
        existing_comment_id = self.seed_existing_comment(instruction_id, message)
        result = self.invoke_after_run_transition_at_envelope_write(
            {
                "instruction_id": instruction_id,
                "task_id": self.target_task_id,
                "message": message,
                "run_id": run_id,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            },
            f"UPDATE task_runs SET status='running', outcome=NULL, ended_at=NULL "
            f"WHERE id={run_id}; "
            f"UPDATE tasks SET status='running', current_run_id={run_id} "
            f"WHERE id='{self.target_task_id}';",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid_run_binding", result.stderr)
        database = self.query_database()
        self.assertEqual(
            [comment["id"] for comment in database["comments"]],
            [existing_comment_id],
        )
        self.assertEqual(database["envelopes"], [])

    def test_newer_run_at_comment_boundary_is_rejected_without_writes(self):
        run_id = self.seed_run(
            "blocked",
            make_current=False,
            outcome="blocked",
        )
        self.set_target_state("blocked")
        result = self.invoke_after_run_transition_at_comment_write(
            {
                "instruction_id": "2a000000-0000-4000-8000-000000000001",
                "task_id": self.target_task_id,
                "message": "더 최신 실행이 생기면 이전 요청을 기록하면 안 됩니다.",
                "run_id": run_id,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            },
            "INSERT INTO task_runs"
            "(task_id, profile, status, started_at, ended_at, outcome) "
            f"VALUES ('{self.target_task_id}', 'rune-implementer', "
            "'blocked', 3, 4, 'blocked');",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid_run_binding", result.stderr)
        database = self.query_database()
        self.assertEqual(database["comments"], [])
        self.assertEqual(database["envelopes"], [])

    def test_newer_run_at_envelope_boundary_rejects_recovery(self):
        instruction_id = "2b000000-0000-4000-8000-000000000001"
        message = "봉투 복구 전 더 최신 실행이 생기면 거부해야 합니다."
        run_id = self.seed_run(
            "blocked",
            make_current=False,
            outcome="blocked",
        )
        self.set_target_state("blocked")
        existing_comment_id = self.seed_existing_comment(instruction_id, message)
        result = self.invoke_after_run_transition_at_envelope_write(
            {
                "instruction_id": instruction_id,
                "task_id": self.target_task_id,
                "message": message,
                "run_id": run_id,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            },
            "INSERT INTO task_runs"
            "(task_id, profile, status, started_at, ended_at, outcome) "
            f"VALUES ('{self.target_task_id}', 'rune-implementer', "
            "'blocked', 3, 4, 'blocked');",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid_run_binding", result.stderr)
        database = self.query_database()
        self.assertEqual(
            [comment["id"] for comment in database["comments"]],
            [existing_comment_id],
        )
        self.assertEqual(database["envelopes"], [])

    def test_valid_blocked_binding_recovers_comment_only_state(self):
        instruction_id = "2c000000-0000-4000-8000-000000000001"
        message = "유효한 차단 실행의 기존 댓글에서는 봉투를 복구해야 합니다."
        run_id = self.seed_run(
            "blocked",
            make_current=False,
            outcome="blocked",
        )
        self.set_target_state("blocked")
        existing_comment_id = self.seed_existing_comment(instruction_id, message)

        result = self.invoke(
            {
                "instruction_id": instruction_id,
                "task_id": self.target_task_id,
                "message": message,
                "run_id": run_id,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            }
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        database = self.query_database()
        self.assertEqual(
            [comment["id"] for comment in database["comments"]],
            [existing_comment_id],
        )
        self.assertEqual(len(database["envelopes"]), 1)

    def test_older_blocked_binding_rejects_comment_only_recovery(self):
        instruction_id = "2d000000-0000-4000-8000-000000000001"
        message = "이전 차단 실행의 기존 댓글에서는 봉투를 만들면 안 됩니다."
        older_run_id = self.seed_run(
            "blocked",
            make_current=False,
            outcome="blocked",
            started_at=1,
        )
        self.seed_run(
            "blocked",
            make_current=False,
            outcome="blocked",
            started_at=3,
        )
        self.set_target_state("blocked")
        existing_comment_id = self.seed_existing_comment(instruction_id, message)

        result = self.invoke(
            {
                "instruction_id": instruction_id,
                "task_id": self.target_task_id,
                "message": message,
                "run_id": older_run_id,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid_run_binding", result.stderr)
        database = self.query_database()
        self.assertEqual(
            [comment["id"] for comment in database["comments"]],
            [existing_comment_id],
        )
        self.assertEqual(database["envelopes"], [])

    def test_highest_run_id_is_authoritative_even_with_an_older_started_at(self):
        self.seed_run(
            "blocked",
            make_current=False,
            outcome="blocked",
            started_at=100,
        )
        latest_run_id = self.seed_run(
            "blocked",
            make_current=False,
            outcome="blocked",
            started_at=1,
        )
        self.set_target_state("blocked")

        result = self.invoke(
            {
                "instruction_id": "2e000000-0000-4000-8000-000000000001",
                "task_id": self.target_task_id,
                "message": "시작 시각과 무관하게 가장 큰 실행 ID를 사용합니다.",
                "run_id": latest_run_id,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            }
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        database = self.query_database()
        self.assertEqual(len(database["comments"]), 1)
        self.assertEqual(len(database["envelopes"]), 1)

    def test_older_blocked_run_is_rejected_when_newest_run_is_terminal(self):
        older_run_id = self.seed_run(
            "blocked",
            make_current=False,
            outcome="blocked",
            started_at=1,
        )
        self.seed_run(
            "done",
            make_current=False,
            outcome="completed",
            started_at=3,
        )
        self.set_target_state("blocked")

        result = self.invoke(
            {
                "instruction_id": "2f000000-0000-4000-8000-000000000001",
                "task_id": self.target_task_id,
                "message": "최신 실행이 종료됐으면 이전 차단 실행은 권위가 없습니다.",
                "run_id": older_run_id,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid_run_binding", result.stderr)
        database = self.query_database()
        self.assertEqual(database["comments"], [])
        self.assertEqual(database["envelopes"], [])

    def test_blocked_target_rejects_terminal_run_outcomes(self):
        terminal_outcomes = (
            "done",
            "completed",
            "crashed",
            "timed_out",
            "failed",
            "released",
            "reclaimed",
            "replaced",
        )
        for index, outcome in enumerate(terminal_outcomes, start=1):
            with self.subTest(outcome=outcome):
                run_id = self.seed_run(
                    "blocked",
                    make_current=False,
                    outcome=outcome,
                    started_at=index * 2,
                )
                self.set_target_state("blocked")
                result = self.invoke(
                    {
                        "instruction_id": f"31000000-0000-4000-8000-{index:012d}",
                        "task_id": self.target_task_id,
                        "message": f"{outcome} 결과에는 기록되면 안 됩니다.",
                        "run_id": run_id,
                        "selected_option_id": None,
                        "client_source": "hermes-monitor",
                    }
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("invalid_run_binding", result.stderr)
                database = self.query_database()
                self.assertEqual(database["comments"], [])
                self.assertEqual(database["envelopes"], [])

    def test_nonrunning_current_runs_are_rejected_without_writes(self):
        terminal_statuses = (
            "done",
            "completed",
            "blocked",
            "crashed",
            "timed_out",
            "failed",
            "released",
            "reclaimed",
            "replaced",
        )
        for index, status in enumerate(terminal_statuses, start=1):
            with self.subTest(status=status):
                run_id = self.seed_run(status)
                result = self.invoke(
                    {
                        "instruction_id": f"30000000-0000-4000-8000-{index:012d}",
                        "task_id": self.target_task_id,
                        "message": f"{status} 실행에는 기록되면 안 됩니다.",
                        "run_id": run_id,
                        "selected_option_id": None,
                        "client_source": "hermes-monitor",
                    }
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("invalid_run_binding", result.stderr)
                self.assertNotIn(f"{status} 실행", result.stdout + result.stderr)
                database = self.query_database()
                self.assertEqual(database["comments"], [])
                self.assertEqual(database["envelopes"], [])

    def test_replaced_run_is_rejected_without_writes(self):
        replaced_run_id = self.seed_run("running", make_current=False)
        self.seed_run("running")
        result = self.invoke(
            {
                "instruction_id": "40000000-0000-4000-8000-000000000001",
                "task_id": self.target_task_id,
                "message": "교체된 실행에는 기록되면 안 됩니다.",
                "run_id": replaced_run_id,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid_run_binding", result.stderr)
        database = self.query_database()
        self.assertEqual(database["comments"], [])
        self.assertEqual(database["envelopes"], [])

    def test_cross_task_running_run_is_rejected_without_writes(self):
        other_task_id = self.create_target("other-instruction-target")
        other_run_id = self.seed_run("running", task_id=other_task_id)
        result = self.invoke(
            {
                "instruction_id": "50000000-0000-4000-8000-000000000001",
                "task_id": self.target_task_id,
                "message": "다른 작업의 실행에는 결합되면 안 됩니다.",
                "run_id": other_run_id,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid_run_binding", result.stderr)
        database = self.query_database()
        self.assertEqual(database["comments"], [])
        self.assertEqual(database["envelopes"], [])

    def test_run_transition_at_comment_write_boundary_is_rejected_without_writes(self):
        run_id = self.seed_run("running")
        result = self.invoke_after_run_transition_at_comment_write(
            {
                "instruction_id": "60000000-0000-4000-8000-000000000001",
                "task_id": self.target_task_id,
                "message": "기록 경계에서 종료된 실행에는 기록되면 안 됩니다.",
                "run_id": run_id,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid_run_binding", result.stderr)
        database = self.query_database()
        self.assertEqual(database["comments"], [])
        self.assertEqual(database["envelopes"], [])

    def test_run_transition_at_envelope_write_boundary_rejects_recovery(self):
        instruction_id = "70000000-0000-4000-8000-000000000001"
        message = "봉투 기록 경계에서 종료된 실행에는 기록되면 안 됩니다."
        run_id = self.seed_run("running")
        connection = sqlite3.connect(self.database)
        cursor = connection.execute(
            "INSERT INTO task_comments(task_id, author, body, created_at) "
            "VALUES (?, 'user', ?, 1)",
            (
                self.target_task_id,
                f"{message}\n\n<!-- hermes-monitor-instruction:{instruction_id} -->",
            ),
        )
        existing_comment_id = cursor.lastrowid
        connection.commit()
        connection.close()

        result = self.invoke_after_run_transition_at_envelope_write(
            {
                "instruction_id": instruction_id,
                "task_id": self.target_task_id,
                "message": message,
                "run_id": run_id,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid_run_binding", result.stderr)
        database = self.query_database()
        self.assertEqual(
            [comment["id"] for comment in database["comments"]],
            [existing_comment_id],
        )
        self.assertEqual(database["envelopes"], [])

    def test_retry_recovers_comment_only_partial_state(self):
        instruction_id = "dddddddd-eeee-4fff-8aaa-bbbbbbbbbbbb"
        message = "댓글 기록 뒤 프로세스가 종료되어도 봉투 생성은 복구되어야 합니다."
        environment = self.environment.copy()
        environment.update(
            {
                "TARGET_TASK_ID": self.target_task_id,
                "COMMENT_BODY": f"{message}\n\n<!-- hermes-monitor-instruction:{instruction_id} -->",
            }
        )
        subprocess.run(
            [
                str(PYTHON),
                "-c",
                "import os; from hermes_cli.kanban_db import add_comment, connect; "
                "c=connect(); add_comment(c, os.environ['TARGET_TASK_ID'], 'user', "
                "os.environ['COMMENT_BODY']); c.close()",
            ],
            env=environment,
            check=True,
            capture_output=True,
            text=True,
        )

        result = self.invoke(
            {
                "instruction_id": instruction_id,
                "task_id": self.target_task_id,
                "message": message,
                "run_id": None,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            }
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertTrue(receipt["duplicate"])
        self.assertEqual(receipt["instruction_id"], instruction_id)
        database = self.query_database()
        self.assertEqual(len(database["comments"]), 1)
        self.assertEqual(len(database["envelopes"]), 1)

    def test_invalid_payload_is_rejected_without_writes_or_message_echo(self):
        message = "secret invalid payload value"
        result = self.invoke(
            {
                "instruction_id": "not-a-uuid",
                "task_id": self.target_task_id,
                "message": message,
                "run_id": None,
                "selected_option_id": None,
                "client_source": "hermes-monitor",
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(message, result.stdout + result.stderr)
        database = self.query_database()
        self.assertEqual(database["comments"], [])
        self.assertEqual(database["envelopes"], [])


if __name__ == "__main__":
    unittest.main()
