#!/usr/bin/env python3
"""Create a coherent, standalone SQLite backup and stream it to stdout."""

import os
import signal
import sqlite3
import sys
import tempfile
import urllib.parse


_cancelled = False


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


def _backup_child(source_uri, temporary_path):
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    signal.signal(signal.SIGHUP, signal.SIG_DFL)
    source = None
    destination = None
    exit_code = 0
    try:
        source = sqlite3.connect(source_uri, uri=True)
        destination = sqlite3.connect(temporary_path)
        source.backup(destination)
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


def _run_backup(source_uri, temporary_path):
    child_pid = os.fork()
    if child_pid == 0:
        _backup_child(source_uri, temporary_path)

    try:
        waited_pid, status = os.waitpid(child_pid, 0)
    except BaseException:
        try:
            os.kill(child_pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(child_pid, 0)
        except ChildProcessError:
            pass
        raise

    if waited_pid != child_pid or not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
        raise RuntimeError("SQLite online backup subprocess failed")


def stream_snapshot(source_path):
    quoted_path = urllib.parse.quote(source_path, safe="/")
    source_uri = f"file:{quoted_path}?mode=ro"
    temporary_path = None
    destination = None

    try:
        descriptor, temporary_path = tempfile.mkstemp(prefix="hermes-monitor-snapshot-", suffix=".db")
        os.fchmod(descriptor, 0o600)
        os.close(descriptor)

        _run_backup(source_uri, temporary_path)
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


def main():
    if len(sys.argv) != 2:
        raise RuntimeError("expected exactly one source database path")
    signal.signal(signal.SIGTERM, _cancel)
    signal.signal(signal.SIGHUP, _cancel)
    stream_snapshot(sys.argv[1])


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"SQLite snapshot helper failed: {type(error).__name__}: {error}", file=sys.stderr)
        raise SystemExit(1)
