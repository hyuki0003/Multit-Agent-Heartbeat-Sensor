import json
import os
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
from hermes_cli.kanban_db import connect
c = connect()
comments = [dict(row) for row in c.execute(
    "SELECT id, task_id, author, body FROM task_comments ORDER BY id"
).fetchall()]
envelopes = [dict(row) for row in c.execute(
    "SELECT id, title, body, assignee, workspace_kind, workspace_path, "
    "max_runtime_seconds, idempotency_key FROM tasks WHERE idempotency_key LIKE 'hermes-monitor:%'"
).fetchall()]
print(json.dumps({"comments": comments, "envelopes": envelopes}, ensure_ascii=False))
"""
        result = subprocess.run(
            [str(PYTHON), "-c", query],
            env=self.environment,
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
