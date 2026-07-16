#!/usr/bin/env python3
"""Create a coherent, standalone SQLite backup and stream it to stdout."""

import os
import signal
import sqlite3
import sys
import tempfile
import time
import urllib.parse


_cancelled = False
FULL_BACKUP_MODE = "full"
STATE_SESSIONS_MODE = "state-sessions"
DEFAULT_TIMEOUT_SECONDS = 10.0
KANBAN_DATABASE_PATH = "/home/dhlee/.hermes/kanban.db"
STATE_DATABASE_PATH = "/home/dhlee/.hermes/state.db"
SNAPSHOT_MODES_BY_PATH = {
    KANBAN_DATABASE_PATH: FULL_BACKUP_MODE,
    STATE_DATABASE_PATH: STATE_SESSIONS_MODE,
}
STATE_SESSION_COLUMNS = {
    "id",
    "source",
    "user_id",
    "model",
    "parent_session_id",
    "started_at",
    "ended_at",
    "end_reason",
    "message_count",
    "tool_call_count",
    "cwd",
    "title",
    "handoff_state",
}


def _cancel(_signum, _frame):
    global _cancelled
    _cancelled = True
    raise InterruptedError("snapshot cancelled")


def _check_cancelled(*_progress):
    if _cancelled:
        raise InterruptedError("snapshot cancelled")


def _remove_snapshot_files(path):
    for suffix in ("", "-journal", "-wal", "-shm"):
        try:
            os.unlink(path + suffix)
        except FileNotFoundError:
            pass


def _project_state_sessions(source, destination):
    source.execute("BEGIN")
    schema_row = source.execute(
        "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = 'sessions'"
    ).fetchone()
    if schema_row is None or not schema_row[0]:
        raise RuntimeError("state database has no sessions table schema")
    columns = [row[1] for row in source.execute("PRAGMA table_info(sessions)")]
    missing = STATE_SESSION_COLUMNS.difference(columns)
    if missing:
        raise RuntimeError(f"sessions table is missing required columns: {sorted(missing)!r}")

    destination.execute(schema_row[0])
    rows = source.execute("SELECT * FROM sessions")
    placeholders = ", ".join("?" for _ in columns)
    while True:
        batch = rows.fetchmany(256)
        if not batch:
            break
        destination.executemany(f"INSERT INTO sessions VALUES ({placeholders})", batch)
    destination.commit()


def _backup_child(source_uri, temporary_path, mode):
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    signal.signal(signal.SIGHUP, signal.SIG_DFL)
    source = None
    destination = None
    exit_code = 0
    try:
        source = sqlite3.connect(source_uri, uri=True)
        destination = sqlite3.connect(temporary_path)
        if mode == FULL_BACKUP_MODE:
            source.backup(destination)
        elif mode == STATE_SESSIONS_MODE:
            _project_state_sessions(source, destination)
        else:
            raise RuntimeError(f"unsupported fixed snapshot mode: {mode!r}")
    except BaseException as error:
        print(
            f"SQLite snapshot backup failed: {type(error).__name__}: {error}",
            file=sys.stderr,
            flush=True,
        )
        exit_code = 1
    finally:
        if destination is not None:
            destination.close()
        if source is not None:
            source.close()
    os._exit(exit_code)


def _kill_and_reap(child_pid):
    try:
        os.kill(child_pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(child_pid, 0)
    except ChildProcessError:
        pass


def _run_backup(source_uri, temporary_path, mode, timeout_seconds):
    child_pid = os.fork()
    if child_pid == 0:
        _backup_child(source_uri, temporary_path, mode)

    deadline = time.monotonic() + timeout_seconds
    try:
        while True:
            waited_pid, status = os.waitpid(child_pid, os.WNOHANG)
            if waited_pid == child_pid:
                break
            if time.monotonic() >= deadline:
                raise TimeoutError(
                    f"SQLite snapshot backup timed out after {timeout_seconds:g} seconds"
                )
            time.sleep(0.01)
    except BaseException:
        _kill_and_reap(child_pid)
        raise

    if waited_pid != child_pid or not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
        raise RuntimeError("SQLite online backup subprocess failed")


def stream_snapshot(source_path, mode, timeout_seconds=DEFAULT_TIMEOUT_SECONDS):
    if mode not in (FULL_BACKUP_MODE, STATE_SESSIONS_MODE):
        raise RuntimeError(f"unsupported fixed snapshot mode: {mode!r}")
    if timeout_seconds <= 0:
        raise RuntimeError("snapshot timeout must be positive")
    quoted_path = urllib.parse.quote(source_path, safe="/")
    source_uri = f"file:{quoted_path}?mode=ro"
    temporary_path = None
    destination = None

    try:
        descriptor, temporary_path = tempfile.mkstemp(prefix="hermes-monitor-snapshot-", suffix=".db")
        os.fchmod(descriptor, 0o600)
        os.close(descriptor)

        _run_backup(source_uri, temporary_path, mode, timeout_seconds)
        _check_cancelled()
        destination = sqlite3.connect(temporary_path)
        mode_row = destination.execute("PRAGMA journal_mode=DELETE").fetchone()
        mode = str(mode_row[0]).lower() if mode_row else ""
        if mode != "delete":
            raise RuntimeError(f"snapshot journal mode is {mode!r}, expected 'delete'")
        check = destination.execute("PRAGMA quick_check").fetchall()
        if check != [("ok",)]:
            raise RuntimeError(f"snapshot quick_check failed: {check!r}")
        destination.close()
        destination = None

        with open(temporary_path, "rb") as snapshot:
            while True:
                _check_cancelled()
                chunk = snapshot.read(1024 * 1024)
                if not chunk:
                    break
                sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
    finally:
        try:
            if destination is not None:
                destination.close()
        finally:
            if temporary_path is not None:
                _remove_snapshot_files(temporary_path)


def snapshot_mode_for_path(source_path):
    try:
        return SNAPSHOT_MODES_BY_PATH[source_path]
    except KeyError:
        raise RuntimeError(f"source database path is not approved: {source_path!r}") from None


def main():
    if len(sys.argv) != 2:
        raise RuntimeError("expected exactly one source database path")
    source_path = sys.argv[1]
    mode = snapshot_mode_for_path(source_path)
    signal.signal(signal.SIGTERM, _cancel)
    signal.signal(signal.SIGHUP, _cancel)
    stream_snapshot(source_path, mode)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"SQLite snapshot helper failed: {type(error).__name__}: {error}", file=sys.stderr)
        raise SystemExit(1)
