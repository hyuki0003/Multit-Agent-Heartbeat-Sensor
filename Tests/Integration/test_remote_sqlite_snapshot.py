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


class RemoteSQLiteSnapshotIntegrationTests(unittest.TestCase):
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
            with output.open("wb") as stdout:
                result = subprocess.run(
                    [sys.executable, str(HELPER), str(source)],
                    stdout=stdout,
                    stderr=subprocess.PIPE,
                    env=environment,
                    check=False,
                )

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
            remote_tmp = root / "remote-tmp"
            remote_tmp.mkdir()
            environment = os.environ.copy()
            environment["TMPDIR"] = str(remote_tmp)

            result = subprocess.run(
                [sys.executable, str(HELPER), str(root / "missing.db")],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"")
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
                [sys.executable, str(HELPER), str(source)],
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
                    [sys.executable, str(HELPER), str(source)],
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
