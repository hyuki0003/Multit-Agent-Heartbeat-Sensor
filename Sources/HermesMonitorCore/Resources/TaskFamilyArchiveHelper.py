#!/usr/bin/env python3
"""Archive bounded completed task families through the canonical Kanban API."""

from __future__ import annotations

import json
import sqlite3
import sys
from collections import defaultdict
from typing import Any

from hermes_cli.kanban_db import archive_task, connect, write_txn


MAX_INPUT_BYTES = 4 * 1024
MAX_FAMILIES_PER_REFRESH = 4
MAX_TASKS_PER_REFRESH = 32
EXPECTED_KEYS = {"max_families", "max_tasks", "client_source"}


class RequestError(ValueError):
    pass


class GraphError(ValueError):
    pass


class _AtomicCanonicalConnection:
    """Nest canonical archive transactions inside one preflight transaction."""

    _SAVEPOINT = "hermes_monitor_family_archive"

    def __init__(self, connection: Any):
        self._connection = connection
        self._savepoint_active = False

    def execute(self, sql: str, parameters: Any = ()) -> Any:
        command = sql.strip().upper()
        if command == "BEGIN IMMEDIATE":
            if self._savepoint_active:
                raise sqlite3.OperationalError("nested canonical transaction")
            result = self._connection.execute(f"SAVEPOINT {self._SAVEPOINT}")
            self._savepoint_active = True
            return result
        if command == "COMMIT":
            try:
                return self._connection.execute(f"RELEASE SAVEPOINT {self._SAVEPOINT}")
            finally:
                self._savepoint_active = False
        if command == "ROLLBACK":
            try:
                self._connection.execute(f"ROLLBACK TO SAVEPOINT {self._SAVEPOINT}")
                return self._connection.execute(f"RELEASE SAVEPOINT {self._SAVEPOINT}")
            finally:
                self._savepoint_active = False
        return self._connection.execute(sql, parameters)

    def __getattr__(self, name: str) -> Any:
        return getattr(self._connection, name)


def _read_request() -> dict[str, Any]:
    raw = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
    if len(raw) > MAX_INPUT_BYTES:
        raise RequestError("payload_too_large")
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RequestError("invalid_json") from error
    if not isinstance(payload, dict) or set(payload) != EXPECTED_KEYS:
        raise RequestError("invalid_contract")
    if payload["client_source"] != "hermes-monitor":
        raise RequestError("invalid_client_source")
    for key in ("max_families", "max_tasks"):
        value = payload[key]
        if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
            raise RequestError(f"invalid_{key}")
    if payload["max_families"] > MAX_FAMILIES_PER_REFRESH:
        raise RequestError("invalid_max_families")
    if payload["max_tasks"] > MAX_TASKS_PER_REFRESH:
        raise RequestError("invalid_max_tasks")
    return payload


def _plan(conn: Any, max_families: int, max_tasks: int) -> tuple[list[list[str]], int, bool]:
    rows = conn.execute(
        "SELECT id, status, created_at FROM tasks ORDER BY created_at, id"
    ).fetchall()
    tasks = {row["id"]: row for row in rows}
    links = conn.execute(
        "SELECT parent_id, child_id FROM task_links ORDER BY parent_id, child_id"
    ).fetchall()
    for link in links:
        if (
            link["parent_id"] not in tasks
            or link["child_id"] not in tasks
            or link["parent_id"] == link["child_id"]
        ):
            raise GraphError("malformed_graph")

    active_ids = {task_id for task_id, row in tasks.items() if row["status"] != "archived"}
    children: dict[str, set[str]] = defaultdict(set)
    parents: dict[str, set[str]] = defaultdict(set)
    neighbors: dict[str, set[str]] = defaultdict(set)
    for link in links:
        parent_id = link["parent_id"]
        child_id = link["child_id"]
        children[parent_id].add(child_id)
        parents[child_id].add(parent_id)
        neighbors[parent_id].add(child_id)
        neighbors[child_id].add(parent_id)

    indegree = {task_id: len(parents[task_id]) for task_id in tasks}
    ready = sorted(task_id for task_id, degree in indegree.items() if degree == 0)
    topological: list[str] = []
    while ready:
        task_id = ready.pop(0)
        topological.append(task_id)
        for child_id in sorted(children[task_id]):
            indegree[child_id] -= 1
            if indegree[child_id] == 0:
                ready.append(child_id)
                ready.sort()
    if len(topological) != len(tasks):
        raise GraphError("malformed_graph")

    components: list[set[str]] = []
    unseen = set(tasks)
    while unseen:
        start = min(unseen)
        component: set[str] = set()
        stack = [start]
        while stack:
            task_id = stack.pop()
            if task_id in component:
                continue
            component.add(task_id)
            unseen.discard(task_id)
            stack.extend(neighbors[task_id] - component)
        components.append(component)

    components = [component for component in components if component & active_ids]

    def component_key(component: set[str]) -> tuple[int, str]:
        roots = sorted(task_id for task_id in component if not (parents[task_id] & component))
        root_rows = [tasks[task_id] for task_id in roots]
        return min((int(row["created_at"]), row["id"]) for row in root_rows)

    components.sort(key=component_key)
    eligible = [
        component
        for component in components
        if all(
            tasks[task_id]["status"] == "done"
            for task_id in component & active_ids
        )
    ]
    selected: list[list[str]] = []
    selected_ids: set[str] = set()
    for component in eligible:
        targets = component & active_ids
        if len(selected) >= max_families or len(selected_ids) + len(targets) > max_tasks:
            continue
        order = [task_id for task_id in reversed(topological) if task_id in targets]
        selected.append(order)
        selected_ids.update(targets)
    bounded = len(selected) < len(eligible)
    deferred_count = len(components) - len(selected)
    return selected, deferred_count, bounded


def _receipt(
    outcome: str,
    archived_families: list[list[str]],
    deferred_family_count: int,
    bounded: bool,
    reason: str | None = None,
) -> dict[str, Any]:
    archived_task_ids = [task_id for family in archived_families for task_id in family]
    return {
        "outcome": outcome,
        "archived_family_count": len(archived_families),
        "archived_task_count": len(archived_task_ids),
        "archived_task_ids": archived_task_ids,
        "deferred_family_count": deferred_family_count,
        "bounded": bounded,
        "reason": reason,
    }


def _archive(request: dict[str, Any]) -> dict[str, Any]:
    conn = connect()
    archived_families: list[list[str]] = []
    try:
        try:
            with write_txn(conn):
                selected, deferred_count, bounded = _plan(
                    conn,
                    request["max_families"],
                    request["max_tasks"],
                )
                canonical_conn = _AtomicCanonicalConnection(conn)
                for family in selected:
                    for task_id in family:
                        if not archive_task(canonical_conn, task_id):
                            raise RequestError("archive_state_changed")
                    archived_families.append(family)
        except GraphError:
            return _receipt("rejected", [], 0, False, "malformed_graph")
        return _receipt(
            "archived" if archived_families else "noop",
            archived_families,
            deferred_count,
            bounded,
        )
    finally:
        conn.close()


def main() -> int:
    try:
        receipt = _archive(_read_request())
    except Exception as error:
        code = str(error) if isinstance(error, RequestError) else "archive_failed"
        sys.stderr.write(json.dumps({"outcome": "failed", "reason": code}) + "\n")
        return 2
    sys.stdout.write(json.dumps(receipt, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
