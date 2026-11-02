"""Offline tests: an in-memory stand-in for the Google Tasks API client.

Run: uv run --group dev pytest -q
"""

from __future__ import annotations

import asyncio
import itertools
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import server  # noqa: E402

_ids = itertools.count(1)


class _Req:
    def __init__(self, fn):
        self._fn = fn

    def execute(self):
        return self._fn()


class _TaskLists:
    def __init__(self, store):
        self.s = store

    def list(self, maxResults=100, pageToken=None):
        return _Req(lambda: {"items": [dict(v) for v in self.s.lists.values()]})

    def get(self, tasklist):
        def f():
            lid = self.s.default if tasklist == "@default" else tasklist
            return dict(self.s.lists[lid])
        return _Req(f)

    def insert(self, body):
        def f():
            lid = f"L{next(_ids)}"
            self.s.lists[lid] = {"id": lid, "title": body["title"]}
            self.s.tasks[lid] = {}
            return dict(self.s.lists[lid])
        return _Req(f)

    def patch(self, tasklist, body):
        def f():
            self.s.lists[tasklist].update(body)
            return dict(self.s.lists[tasklist])
        return _Req(f)

    def delete(self, tasklist):
        def f():
            del self.s.lists[tasklist]
            del self.s.tasks[tasklist]
            return ""
        return _Req(f)


class _Tasks:
    def __init__(self, store):
        self.s = store

    def list(self, tasklist, pageToken=None, maxResults=100, showCompleted=True, showHidden=False, dueMin=None, dueMax=None):
        self.s.last_list_kwargs = dict(showCompleted=showCompleted, dueMin=dueMin, dueMax=dueMax)

        def f():
            items = []
            for t in self.s.tasks[tasklist].values():
                if not showCompleted and t.get("status") == "completed":
                    continue
                if dueMin and (not t.get("due") or t["due"] < dueMin):
                    continue
                if dueMax and (not t.get("due") or t["due"] > dueMax):
                    continue
                items.append(dict(t))
            return {"items": items}
        return _Req(f)

    def insert(self, tasklist, body, parent=None):
        def f():
            tid = f"T{next(_ids)}"
            # New tasks go first: smaller position sorts earlier.
            pos = f"{10**9 - next(_ids):020d}"
            t = {"id": tid, "status": "needsAction", "position": pos, **body}
            if parent:
                t["parent"] = parent
            self.s.tasks[tasklist][tid] = t
            return dict(t)
        return _Req(f)

    def patch(self, tasklist, task, body):
        def f():
            t = self.s.tasks[tasklist][task]
            for k, v in body.items():
                if v is None:
                    t.pop(k, None)
                else:
                    t[k] = v
            return dict(t)
        return _Req(f)

    def move(self, tasklist, task, parent=None, previous=None, destinationTasklist=None):
        def f():
            t = self.s.tasks[tasklist].pop(task)
            t.pop("parent", None)
            if parent:
                t["parent"] = parent
            dest = destinationTasklist or tasklist
            self.s.tasks[dest][task] = t
            self.s.last_move = dict(parent=parent, previous=previous, destinationTasklist=destinationTasklist)
            return dict(t)
        return _Req(f)

    def delete(self, tasklist, task):
        def f():
            del self.s.tasks[tasklist][task]
            return ""
        return _Req(f)


class Store:
    """Plain in-memory state: task lists and tasks keyed by list id."""

    def __init__(self):
        self.default = "L0"
        self.lists = {"L0": {"id": "L0", "title": "My Tasks"}}
        self.tasks = {"L0": {}}


class FakeService:
    """Exposes .tasklists() / .tasks() like the googleapiclient Tasks client."""

    def __init__(self, store):
        self.store = store

    def tasklists(self):
        return _TaskLists(self.store)

    def tasks(self):
        return _Tasks(self.store)


@pytest.fixture
def fake():
    store = Store()
    server.set_service(FakeService(store))
    yield store
    server.set_service(None)


def test_company_lists_with_subtasks(fake):
    r = server.create_task_list("Acme")
    assert r["created"] is True
    assert server.create_task_list("acme")["created"] is False  # idempotent, case-insensitive

    parent = server.create_task("Acme kickoff", task_list="Acme", due="2026-09-24", notes="bring the contract")
    assert parent["due"] == "2026-09-24"
    assert parent["list"] == "Acme"
    sub1 = server.create_task("Draft agenda", task_list="Acme", parent_task_id=parent["id"])
    sub2 = server.create_task("Book room", task_list="Acme", parent_task_id=parent["id"])
    assert sub1["parent_task_id"] == parent["id"]

    out = server.list_tasks("Acme")
    assert out["list"] == "Acme"
    assert len(out["tasks"]) == 1
    subs = out["tasks"][0]["subtasks"]
    assert {s["id"] for s in subs} == {sub1["id"], sub2["id"]}
    assert "subtasks" not in subs[0]


def test_due_filters_and_completion(fake):
    server.create_task_list("Globex")
    a = server.create_task("Send invoice", task_list="Globex", due="2026-09-24")
    server.create_task("Later", task_list="Globex", due="2026-10-10")
    server.create_task("Undated", task_list="Globex")

    due_this_week = server.list_tasks("Globex", due_on_or_before="2026-09-27")["tasks"]
    assert [t["title"] for t in due_this_week] == ["Send invoice"]

    server.complete_task(a["id"], task_list="Globex")
    assert all(t["id"] != a["id"] for t in server.list_tasks("Globex")["tasks"])
    assert any(t["id"] == a["id"] for t in server.list_tasks("Globex", include_completed=True)["tasks"])

    reopened = server.update_task(a["id"], task_list="Globex", completed=False)
    assert reopened["status"] == "needsAction"

    cleared = server.update_task(a["id"], task_list="Globex", clear_due=True)
    assert "due" not in cleared


def test_move_between_lists_and_search(fake):
    server.create_task_list("Initech")
    t = server.create_task("Quarterly report", notes="numbers from finance")
    moved = server.move_task(t["id"], destination_list="Initech")
    assert moved["list"] == "Initech"
    assert fake.last_move["destinationTasklist"] is not None
    hits = server.search_tasks("finance")
    assert [h["list"] for h in hits] == ["Initech"]

    everything = server.list_all_tasks()
    assert [g["list"] for g in everything] == ["Initech"]


def test_errors(fake):
    with pytest.raises(server.ToolError, match="No task list named"):
        server.create_task("x", task_list="Nope")
    with pytest.raises(server.ToolError, match="YYYY-MM-DD"):
        server.create_task("x", due="next friday")
    with pytest.raises(server.ToolError, match="Nothing to update"):
        server.update_task("T1")


def test_delete(fake):
    server.create_task_list("Tmp")
    t = server.create_task("gone", task_list="Tmp")
    server.delete_task(t["id"], task_list="Tmp")
    assert server.list_tasks("Tmp")["tasks"] == []
    server.delete_task_list("Tmp")
    assert [l["title"] for l in server.list_task_lists()] == ["My Tasks"]


def test_tools_registered_via_mcp(fake):
    tools = asyncio.run(server.mcp.list_tools())
    names = {t.name for t in tools}
    assert names == {
        "list_task_lists", "create_task_list", "rename_task_list", "delete_task_list",
        "list_tasks", "list_all_tasks", "search_tasks", "create_task", "update_task",
        "complete_task", "move_task", "delete_task", "refresh_menu_bar",
    }
    destructive = {t.name for t in tools if t.annotations and t.annotations.destructive_hint}
    assert destructive == {"delete_task_list", "delete_task"}

    server.create_task_list("Acme")
    result = asyncio.run(server.mcp.call_tool("create_task", {"title": "via mcp", "task_list": "Acme", "due": "2026-09-25"}))
    assert "via mcp" in str(result)
