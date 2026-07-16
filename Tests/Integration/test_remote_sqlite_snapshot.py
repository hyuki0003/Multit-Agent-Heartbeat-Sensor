import os
import pathlib
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
HELPER = ROOT / "Sources" / "HermesMonitorCore" / "Resources" / "RemoteSQLiteSnapshot.py"
INTERNAL_RUNNER = """
import importlib.util
import signal
import sys

spec = importlib.util.spec_from_file_location("remote_snapshot", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
signal.signal(signal.SIGTERM, module._cancel)
signal.signal(signal.SIGHUP, module._cancel)
try:
    module.stream_snapshot(sys.argv[2], sys.argv[3], float(sys.argv[4]))
except Exception as error:
    print(f"SQLite snapshot helper failed: {type(error).__name__}: {error}", file=sys.stderr)
    raise SystemExit(1)
"""
MODE_RUNNER = """
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("remote_snapshot", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.snapshot_mode_for_path(sys.argv[2]))
"""


def run_internal_snapshot(source, output, mode, environment, timeout_seconds=10):
    with output.open("wb") as stdout:
        return subprocess.run(
            [
                sys.executable,
                "-c",
                INTERNAL_RUNNER,
                str(HELPER),
                str(source),
                mode,
                str(timeout_seconds),
            ],
            stdout=stdout,
            stderr=subprocess.PIPE,
            env=environment,
            check=False,
        )


class RemoteSQLiteSnapshotIntegrationTests(unittest.TestCase):
    def test_exact_paths_select_fixed_modes_and_arbitrary_path_is_rejected(self):
        cases = [
            ("/home/dhlee/.hermes/kanban.db", b"full\n"),
            ("/home/dhlee/.hermes/state.db", b"state-sessions\n"),
        ]
        for path, expected in cases:
            result = subprocess.run(
                [sys.executable, "-c", MODE_RUNNER, str(HELPER), path],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", errors="replace"))
            self.assertEqual(result.stdout, expected)

        rejected = subprocess.run(
            [sys.executable, "-c", MODE_RUNNER, str(HELPER), "/tmp/state.db"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertEqual(rejected.stdout, b"")
        self.assertIn(b"source database path is not approved", rejected.stderr)

    def test_internal_deadline_stops_locked_backup_and_removes_temporary_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "source.db"
            output = root / "snapshot.db"
            remote_tmp = root / "remote-tmp"
            remote_tmp.mkdir()
            owner = sqlite3.connect(source)
            process = None
            output_handle = None
            try:
                owner.execute("CREATE TABLE markers (value TEXT NOT NULL)")
                owner.execute("INSERT INTO markers VALUES ('committed')")
                owner.commit()
                owner.execute("BEGIN EXCLUSIVE")
                environment = os.environ.copy()
                environment["TMPDIR"] = str(remote_tmp)
                output_handle = output.open("wb")
                process = subprocess.Popen(
                    [
                        sys.executable,
                        "-c",
                        INTERNAL_RUNNER,
                        str(HELPER),
                        str(source),
                        "full",
                        "0.2",
                    ],
                    stdout=output_handle,
                    stderr=subprocess.PIPE,
                    env=environment,
                )
                started = time.monotonic()
                while process.poll() is None and time.monotonic() - started < 1.0:
                    time.sleep(0.01)
                finished_within_bound = process.poll() is not None
                if not finished_within_bound:
                    owner.rollback()
                    owner.close()
                    owner = None
                _, stderr = process.communicate(timeout=5)
                output_handle.close()
                output_handle = None

                self.assertTrue(finished_within_bound, "helper ignored its internal total deadline")
                self.assertNotEqual(process.returncode, 0)
                self.assertEqual(output.read_bytes(), b"")
                self.assertIn(b"timed out after 0.2 seconds", stderr)
                self.assertEqual(list(remote_tmp.iterdir()), [])
            finally:
                if owner is not None:
                    owner.rollback()
                    owner.close()
                if process is not None and process.poll() is None:
                    process.kill()
                    process.communicate(timeout=5)
                if output_handle is not None:
                    output_handle.close()

    def test_state_projection_preserves_sessions_schema_and_rows_without_messages_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "state.db"
            output = root / "snapshot.db"
            remote_tmp = root / "remote-tmp"
            remote_tmp.mkdir()
            sessions_schema = """CREATE TABLE sessions (
                id TEXT PRIMARY KEY, source TEXT NOT NULL, user_id TEXT, model TEXT,
                model_config TEXT, system_prompt TEXT, parent_session_id TEXT,
                started_at REAL NOT NULL, ended_at REAL, end_reason TEXT,
                message_count INTEGER DEFAULT 0, tool_call_count INTEGER DEFAULT 0,
                input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0,
                cache_read_tokens INTEGER DEFAULT 0, cache_write_tokens INTEGER DEFAULT 0,
                reasoning_tokens INTEGER DEFAULT 0, cwd TEXT, billing_provider TEXT,
                billing_base_url TEXT, billing_mode TEXT, estimated_cost_usd REAL,
                actual_cost_usd REAL, cost_status TEXT, cost_source TEXT,
                pricing_version TEXT, title TEXT, api_call_count INTEGER DEFAULT 0,
                handoff_state TEXT, handoff_platform TEXT, handoff_error TEXT,
                rewind_count INTEGER NOT NULL DEFAULT 0,
                archived INTEGER NOT NULL DEFAULT 0,
                FOREIGN KEY (parent_session_id) REFERENCES sessions(id)
            )"""
            with sqlite3.connect(source) as connection:
                connection.execute(sessions_schema)
                connection.execute(
                    "CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, content BLOB)"
                )
                connection.executemany(
                    """
                    INSERT INTO sessions
                        (id, source, user_id, model, parent_session_id, started_at, ended_at,
                         end_reason, message_count, tool_call_count, cwd, title, handoff_state)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        ("s1", "cli", "u1", "m1", None, 1.0, None, None, 2, 1, "/a", "One", None),
                        ("s2", "kanban", None, None, "s1", 2.0, 3.0, "done", 1, 0, "/b", "Two", "sent"),
                    ],
                )
                connection.execute(
                    "INSERT INTO messages (session_id, content) VALUES ('s1', zeroblob(8388608))"
                )

            environment = os.environ.copy()
            environment["TMPDIR"] = str(remote_tmp)
            result = run_internal_snapshot(source, output, "state-sessions", environment)

            self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", errors="replace"))
            self.assertLess(output.stat().st_size * 8, source.stat().st_size)
            with sqlite3.connect(f"file:{source}?mode=ro", uri=True) as original, sqlite3.connect(
                f"file:{output}?mode=ro", uri=True
            ) as snapshot:
                source_schema = original.execute(
                    "SELECT sql FROM sqlite_schema WHERE type='table' AND name='sessions'"
                ).fetchone()[0]
                projected_schema = snapshot.execute(
                    "SELECT sql FROM sqlite_schema WHERE type='table' AND name='sessions'"
                ).fetchone()[0]
                self.assertEqual(projected_schema, source_schema)
                self.assertEqual(
                    snapshot.execute("SELECT * FROM sessions ORDER BY started_at").fetchall(),
                    original.execute("SELECT * FROM sessions ORDER BY started_at").fetchall(),
                )
                self.assertEqual(
                    snapshot.execute("SELECT name FROM sqlite_schema WHERE type='table'").fetchall(),
                    [("sessions",)],
                )
                self.assertEqual(snapshot.execute("PRAGMA quick_check").fetchall(), [("ok",)])
                self.assertEqual(snapshot.execute("PRAGMA journal_mode").fetchone()[0], "delete")
            self.assertEqual(list(remote_tmp.iterdir()), [])

    def test_backup_includes_committed_wal_frames_and_is_standalone_delete_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "source.db"
            output = root / "snapshot.db"
            remote_tmp = root / "remote-tmp"
            remote_tmp.mkdir()

            connection = sqlite3.connect(source)
            self.addCleanup(connection.close)
            self.assertEqual(connection.execute("PRAGMA journal_mode=WAL").fetchone()[0], "wal")
            connection.execute("PRAGMA wal_autocheckpoint=0")
            connection.execute("CREATE TABLE markers (value TEXT NOT NULL)")
            connection.execute("CREATE TABLE payloads (value BLOB NOT NULL)")
            binary_payload = bytes(range(256)) * 8192
            connection.execute("INSERT INTO payloads VALUES (?)", (binary_payload,))
            connection.commit()
            connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            connection.execute("INSERT INTO markers VALUES ('committed-in-wal')")
            connection.commit()
            self.assertTrue(source.with_name(source.name + "-wal").exists())

            main_only = root / "main-only.db"
            main_only.write_bytes(source.read_bytes())
            with sqlite3.connect(f"file:{main_only}?mode=ro", uri=True) as copied:
                self.assertEqual(copied.execute("SELECT count(*) FROM markers").fetchone()[0], 0)

            environment = os.environ.copy()
            environment["TMPDIR"] = str(remote_tmp)
            result = run_internal_snapshot(source, output, "full", environment)

            self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", errors="replace"))
            self.assertEqual(output.read_bytes()[:16], b"SQLite format 3\x00")
            with sqlite3.connect(f"file:{output}?mode=ro", uri=True) as snapshot:
                self.assertEqual(snapshot.execute("PRAGMA quick_check").fetchall(), [("ok",)])
                self.assertEqual(snapshot.execute("PRAGMA journal_mode").fetchone()[0], "delete")
                self.assertEqual(snapshot.execute("SELECT value FROM markers").fetchall(), [("committed-in-wal",)])
                self.assertEqual(snapshot.execute("SELECT value FROM payloads").fetchone()[0], binary_payload)
            self.assertFalse(output.with_name(output.name + "-wal").exists())
            self.assertFalse(output.with_name(output.name + "-shm").exists())
            self.assertEqual(connection.execute("PRAGMA journal_mode").fetchone()[0], "wal")
            self.assertTrue(source.with_name(source.name + "-wal").exists())
            self.assertEqual(list(remote_tmp.iterdir()), [])

    def test_failure_is_explicit_and_removes_remote_temporary_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            output = root / "snapshot.db"
            remote_tmp = root / "remote-tmp"
            remote_tmp.mkdir()
            environment = os.environ.copy()
            environment["TMPDIR"] = str(remote_tmp)

            result = run_internal_snapshot(root / "missing.db", output, "full", environment)

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(output.read_bytes(), b"")
            self.assertIn(b"SQLite snapshot helper failed", result.stderr)
            self.assertEqual(list(remote_tmp.iterdir()), [])

    def test_broken_binary_stream_removes_remote_temporary_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "source.db"
            with sqlite3.connect(source) as connection:
                connection.execute("CREATE TABLE payloads (value BLOB NOT NULL)")
                connection.execute("INSERT INTO payloads VALUES (zeroblob(4194304))")

            remote_tmp = root / "remote-tmp"
            remote_tmp.mkdir()
            environment = os.environ.copy()
            environment["TMPDIR"] = str(remote_tmp)
            process = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    INTERNAL_RUNNER,
                    str(HELPER),
                    str(source),
                    "full",
                    "10",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
            )
            assert process.stdout is not None
            assert process.stderr is not None
            process.stdout.close()
            stderr = process.stderr.read()
            process.stderr.close()
            returncode = process.wait(timeout=30)

            self.assertNotEqual(returncode, 0)
            self.assertIn(b"SQLite snapshot helper failed", stderr)
            self.assertEqual(list(remote_tmp.iterdir()), [])

    def test_sigterm_interrupts_busy_backup_and_removes_remote_temporary_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "source.db"
            owner = sqlite3.connect(source)
            process = None
            try:
                owner.execute("CREATE TABLE markers (value TEXT NOT NULL)")
                owner.execute("INSERT INTO markers VALUES ('committed')")
                owner.commit()
                owner.execute("BEGIN EXCLUSIVE")

                remote_tmp = root / "remote-tmp"
                remote_tmp.mkdir()
                environment = os.environ.copy()
                environment["TMPDIR"] = str(remote_tmp)
                process = subprocess.Popen(
                    [
                        sys.executable,
                        "-c",
                        INTERNAL_RUNNER,
                        str(HELPER),
                        str(source),
                        "full",
                        "10",
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env=environment,
                )
                deadline = time.monotonic() + 5
                while not list(remote_tmp.iterdir()) and time.monotonic() < deadline:
                    self.assertIsNone(process.poll(), "helper exited before creating its temporary artifact")
                    time.sleep(0.01)
                self.assertNotEqual(list(remote_tmp.iterdir()), [])

                process.terminate()
                try:
                    stdout, stderr = process.communicate(timeout=2)
                except subprocess.TimeoutExpired:
                    owner.rollback()
                    owner.close()
                    owner = None
                    process.communicate(timeout=5)
                    self.fail("SIGTERM did not interrupt a busy SQLite backup")

                self.assertNotEqual(process.returncode, 0)
                self.assertEqual(stdout, b"")
                self.assertIn(b"SQLite snapshot helper failed", stderr)
                self.assertEqual(list(remote_tmp.iterdir()), [])
            finally:
                if owner is not None:
                    owner.rollback()
                    owner.close()
                if process is not None and process.poll() is None:
                    process.kill()
                    process.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
