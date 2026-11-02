"""Google Tasks MCP server.

Two backends; the direct API is used whenever token.json exists:
  Direct Google Tasks API (needs an OAuth "Desktop app" client from a Cloud project):
    save the client JSON as credentials.json, then
    uv run server.py auth               # browser sign-in, writes token.json
  Apps Script bridge (no Cloud project):
    uv run server.py bridge-init / bridge-url <URL>

Run:
    uv run server.py                    # stdio MCP server (what Claude launches)
    uv run server.py check              # prints which backend is active and your task lists

credentials.json, token.json and bridge.json live next to this script unless GTASKS_HOME is set.
"""

from __future__ import annotations

import json
import os
import secrets
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import date
from pathlib import Path
from typing import Any

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.types import ToolAnnotations

ROOT = Path(__file__).resolve().parent
HOME = Path(os.environ.get("GTASKS_HOME", ROOT))
BRIDGE_FILE = HOME / "bridge.json"
CREDENTIALS_FILE = HOME / "credentials.json"
TOKEN_FILE = HOME / "token.json"
SCOPES = ["https://www.googleapis.com/auth/tasks"]
SCRIPT_TEMPLATE = ROOT / "apps_script" / "Code.gs"

READ_ONLY = ToolAnnotations(read_only_hint=True, destructive_hint=False)
WRITE = ToolAnnotations(read_only_hint=False, destructive_hint=False)
DESTRUCTIVE = ToolAnnotations(read_only_hint=False, destructive_hint=True)

mcp = MCPServer(
    name="google-tasks",
    instructions=(
        "Manage Google Tasks. Task lists work as top-level groups (for example one list "
        "per company or project). Tasks can have one level of subtasks via parent_task_id. "
        "Due dates are date-only (YYYY-MM-DD); Google Tasks ignores the time of day. "
        "Lists can be referenced by title (case-insensitive) or id; omit to use the default list."
    ),
)


# --------------------------------------------------------------------------- bridge client


def _load_bridge() -> dict:
    if not BRIDGE_FILE.exists():
        raise ToolError(f"No {BRIDGE_FILE}. Run `uv run server.py bridge-init` in {ROOT} (see README).")
    cfg = json.loads(BRIDGE_FILE.read_text())
    if not cfg.get("url"):
        raise ToolError(f"{BRIDGE_FILE} has no url yet. Run `uv run server.py bridge-url <web app URL>`.")
    return cfg


def bridge_call(op: str, args: dict | None = None, cfg: dict | None = None, timeout: float = 30) -> Any:
    """POST one operation to the Apps Script web app. Apps Script answers POST with a 302 to the
    result, which urllib follows as a GET."""
    cfg = cfg or _load_bridge()
    payload = json.dumps({"secret": cfg["secret"], "op": op, "args": args or {}}).encode()
    req = urllib.request.Request(cfg["url"], data=payload, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode()
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            raise ToolError(
                f"Bridge HTTP {e.code}: Google wants a sign-in, so the web app is not open to anonymous "
                "callers. Use the https://script.google.com/macros/s/<id>/exec form of the URL (no /a/<domain>/) "
                "and make sure the deployment has Who has access: Anyone."
            ) from e
        raise ToolError(f"Bridge HTTP {e.code}: {e.read().decode()[:300]}") from e
    except urllib.error.URLError as e:
        raise ToolError(f"Could not reach the Apps Script bridge: {e.reason}") from e
    try:
        data = json.loads(body)
    except json.JSONDecodeError as e:
        # A Google sign-in page instead of JSON means the web app is not deployed with access "Anyone".
        hint = " Redeploy the web app with Who has access: Anyone." if "<html" in body.lower() else ""
        raise ToolError(f"Bridge returned non-JSON.{hint} First bytes: {body[:120]!r}") from e
    if "error" in data:
        raise ToolError(f"Google Tasks error: {data['error']}")
    return data.get("result")


class _Req:
    def __init__(self, op: str, args: dict):
        self.op, self.args = op, {k: v for k, v in args.items() if v is not None or k == "body"}

    def execute(self):
        return bridge_call(self.op, self.args)


class _Resource:
    def __init__(self, prefix: str):
        self.prefix = prefix

    def __getattr__(self, method: str):
        return lambda **kwargs: _Req(f"{self.prefix}.{method}", kwargs)


class BridgeService:
    """Same call shape as googleapiclient's Tasks client: service().tasks().list(...).execute()."""

    def tasklists(self):
        return _Resource("tasklists")

    def tasks(self):
        return _Resource("tasks")


_service = None


def _load_credentials():
    from google.auth.exceptions import RefreshError
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials

    creds = Credentials.from_authorized_user_file(str(TOKEN_FILE), SCOPES)
    if not creds.valid:
        if creds.expired and creds.refresh_token:
            try:
                creds.refresh(Request())
            except RefreshError as e:
                raise ToolError(f"Google token refresh failed ({e}). Re-run `uv run server.py auth` in {ROOT}.") from e
            TOKEN_FILE.write_text(creds.to_json())
        else:
            raise ToolError(f"{TOKEN_FILE} is invalid. Re-run `uv run server.py auth` in {ROOT}.")
    return creds


def backend() -> str:
    return "direct" if TOKEN_FILE.exists() else "bridge"


def service():
    """The Tasks client: direct Google API if token.json exists, else the Apps Script bridge.
    Tests replace this via set_service()."""
    global _service
    if _service is None:
        if backend() == "direct":
            from googleapiclient.discovery import build

            _service = build("tasks", "v1", credentials=_load_credentials(), cache_discovery=False)
        else:
            _load_bridge()  # fail early with a setup hint
            _service = BridgeService()
    return _service


def set_service(svc) -> None:
    global _service
    _service = svc


def _call(request) -> Any:
    try:
        try:
            return request.execute()
        except OSError:
            # A network change (new Wi-Fi address, sleep/wake) leaves the client's kept-open
            # connections dead ("[Errno 49] Can't assign requested address", SSL errors), and
            # httplib2 retries on the same dead connection. Close them all and try once more.
            http = getattr(request, "http", None)
            if http is None:
                raise
            http.close()
            return request.execute()
    except ToolError:
        raise
    except Exception as e:  # googleapiclient.errors.HttpError and friends
        status = getattr(getattr(e, "resp", None), "status", None)
        detail = getattr(e, "reason", None) or str(e)
        raise ToolError(f"Google Tasks API error {status}: {detail}") from e


def run_auth() -> None:
    from google_auth_oauthlib.flow import InstalledAppFlow

    if not CREDENTIALS_FILE.exists():
        sys.exit(
            f"Missing {CREDENTIALS_FILE}. In Google Cloud Console: Google Auth Platform > Clients > "
            "Create client > Desktop app > Download JSON, and save it at that path."
        )
    flow = InstalledAppFlow.from_client_secrets_file(str(CREDENTIALS_FILE), SCOPES)
    creds = flow.run_local_server(port=0, prompt="consent", access_type="offline")
    TOKEN_FILE.write_text(creds.to_json())
    os.chmod(TOKEN_FILE, 0o600)
    print(f"Saved {TOKEN_FILE}.")
    run_check()


def run_check() -> None:
    try:
        lists = _all_lists()
    except ToolError as e:
        sys.exit(f"[{backend()}] failed: {e}")
    print(f"[{backend()}] OK. Task lists: {', '.join(l['title'] for l in lists) or '(none)'}")


# --------------------------------------------------------------------------- setup commands


def bridge_init() -> None:
    cfg = json.loads(BRIDGE_FILE.read_text()) if BRIDGE_FILE.exists() else {}
    cfg.setdefault("secret", secrets.token_urlsafe(32))
    cfg.setdefault("url", "")
    BRIDGE_FILE.write_text(json.dumps(cfg, indent=2))
    os.chmod(BRIDGE_FILE, 0o600)
    code = SCRIPT_TEMPLATE.read_text().replace("__SECRET__", cfg["secret"], 1)
    try:
        subprocess.run(["pbcopy"], input=code.encode(), check=True)
        where = "Copied Code.gs (with your secret) to the clipboard."
    except (FileNotFoundError, subprocess.CalledProcessError):
        out = HOME / "Code.generated.gs"
        out.write_text(code)
        where = f"Wrote {out}; paste its contents."
    print(where)
    print(
        "\nNext:\n"
        "  1. Open https://script.google.com -> New project. Replace everything in Code.gs with the clipboard.\n"
        "  2. Left sidebar: Services (+) -> Google Tasks API -> Add.\n"
        "  3. Deploy -> New deployment -> gear icon -> Web app. Execute as: Me. Who has access: Anyone. Deploy.\n"
        "     Approve the permission prompt (Advanced -> Go to project, if Google warns it is unverified).\n"
        "  4. Copy the Web app URL, then run:  uv run server.py bridge-url <URL>"
    )


def bridge_url(url: str) -> None:
    if not BRIDGE_FILE.exists():
        sys.exit("Run `uv run server.py bridge-init` first.")
    cfg = json.loads(BRIDGE_FILE.read_text())
    cfg["url"] = url.strip()
    BRIDGE_FILE.write_text(json.dumps(cfg, indent=2))
    os.chmod(BRIDGE_FILE, 0o600)
    try:
        who = bridge_call("ping", cfg=cfg)
        lists = bridge_call("tasklists.list", {"maxResults": 100}, cfg=cfg).get("items", [])
    except ToolError as e:
        sys.exit(f"Saved the URL, but the test failed: {e}")
    print(f"Connected as {who.get('user')}. Task lists: {', '.join(l['title'] for l in lists) or '(none)'}")


# --------------------------------------------------------------------------- helpers


def _all_lists() -> list[dict]:
    out, token = [], None
    while True:
        resp = _call(service().tasklists().list(maxResults=100, pageToken=token))
        out.extend(resp.get("items", []))
        token = resp.get("nextPageToken")
        if not token:
            return out


def _resolve_list(ref: str | None) -> dict:
    """Find a task list by id or case-insensitive title. None means the default list."""
    if ref is None or ref == "" or ref == "@default":
        return _call(service().tasklists().get(tasklist="@default"))
    lists = _all_lists()
    for tl in lists:
        if tl["id"] == ref:
            return tl
    matches = [tl for tl in lists if tl["title"].strip().lower() == ref.strip().lower()]
    if len(matches) == 1:
        return matches[0]
    titles = ", ".join(repr(tl["title"]) for tl in lists)
    if not matches:
        raise ToolError(f"No task list named {ref!r}. Available: {titles}")
    raise ToolError(f"Several lists are named {ref!r}; pass the list id instead.")


def _due_to_api(due: str) -> str:
    try:
        d = date.fromisoformat(due[:10])
    except ValueError as e:
        raise ToolError(f"due must be YYYY-MM-DD, got {due!r}") from e
    return f"{d.isoformat()}T00:00:00.000Z"


def _fmt_task(t: dict) -> dict:
    out = {
        "id": t["id"],
        "title": t.get("title", ""),
        "status": t.get("status"),
    }
    if t.get("notes"):
        out["notes"] = t["notes"]
    if t.get("due"):
        out["due"] = t["due"][:10]
    if t.get("parent"):
        out["parent_task_id"] = t["parent"]
    if t.get("completed"):
        out["completed_at"] = t["completed"]
    if t.get("webViewLink"):
        out["link"] = t["webViewLink"]
    return out


def _fetch_tasks(list_id: str, include_completed: bool, due_min=None, due_max=None) -> list[dict]:
    out, token = [], None
    kwargs: dict[str, Any] = {
        "tasklist": list_id,
        "maxResults": 100,
        "showCompleted": include_completed,
        "showHidden": include_completed,
    }
    if due_min:
        kwargs["dueMin"] = _due_to_api(due_min)
    if due_max:
        # Due values are stored as midnight UTC; use end of day so the given date is included.
        kwargs["dueMax"] = f"{date.fromisoformat(due_max[:10]).isoformat()}T23:59:59.999Z"
    while True:
        resp = _call(service().tasks().list(pageToken=token, **kwargs))
        out.extend(resp.get("items", []))
        token = resp.get("nextPageToken")
        if not token:
            return out


def _tree(tasks: list[dict]) -> list[dict]:
    """Nest subtasks under their parents, ordered by the API's position field."""
    tasks = sorted(tasks, key=lambda t: t.get("position", ""))
    by_id = {t["id"]: {**_fmt_task(t), "subtasks": []} for t in tasks}
    roots = []
    for t in tasks:
        node = by_id[t["id"]]
        parent = t.get("parent")
        if parent and parent in by_id:
            by_id[parent]["subtasks"].append(node)
        else:
            roots.append(node)
    for node in by_id.values():
        if not node["subtasks"]:
            del node["subtasks"]
    return roots


# --------------------------------------------------------------------------- menu bar refresh

SWIFTBAR_PLUGIN = os.environ.get("GTASKS_SWIFTBAR_PLUGIN", "gtasks.5m.py")


def _swiftbar_running() -> bool:
    return subprocess.run(["pgrep", "-xq", "SwiftBar"], check=False).returncode == 0


def _refresh_menu_bar() -> None:
    """Ask SwiftBar to re-run the menu bar plugin so changes show immediately. Best effort:
    silently does nothing off macOS, without SwiftBar, or when GTASKS_NO_REFRESH is set.

    Only pokes a SwiftBar that is already running: when the swiftbar:// URL has to launch it,
    SwiftBar 2.1.1 crashes (SIGTRAP) on the URL before its plugins are loaded."""
    if sys.platform != "darwin" or os.environ.get("GTASKS_NO_REFRESH"):
        return
    try:
        if not _swiftbar_running():
            return
        subprocess.run(
            ["open", "-g", f"swiftbar://refreshplugin?plugin={SWIFTBAR_PLUGIN}"],
            timeout=3, capture_output=True, check=False,
        )
    except Exception:  # noqa: BLE001
        pass


@mcp.tool(annotations=WRITE)
def refresh_menu_bar() -> dict:
    """Refresh the SwiftBar Google Tasks menu now (write tools already do this automatically)."""
    _refresh_menu_bar()
    return {"refreshed": SWIFTBAR_PLUGIN}


# --------------------------------------------------------------------------- list tools


@mcp.tool(annotations=READ_ONLY)
def list_task_lists() -> list[dict]:
    """List all Google Tasks lists (id and title)."""
    return [{"id": tl["id"], "title": tl["title"], "updated": tl.get("updated")} for tl in _all_lists()]


@mcp.tool(annotations=WRITE)
def create_task_list(title: str) -> dict:
    """Create a new task list, e.g. one per company or project. Returns the existing list if the title is already taken."""
    for tl in _all_lists():
        if tl["title"].strip().lower() == title.strip().lower():
            return {"id": tl["id"], "title": tl["title"], "created": False}
    tl = _call(service().tasklists().insert(body={"title": title}))
    _refresh_menu_bar()
    return {"id": tl["id"], "title": tl["title"], "created": True}


@mcp.tool(annotations=WRITE)
def rename_task_list(task_list: str, new_title: str) -> dict:
    """Rename a task list (by title or id)."""
    tl = _resolve_list(task_list)
    tl = _call(service().tasklists().patch(tasklist=tl["id"], body={"title": new_title}))
    _refresh_menu_bar()
    return {"id": tl["id"], "title": tl["title"]}


@mcp.tool(annotations=DESTRUCTIVE)
def delete_task_list(task_list: str) -> dict:
    """Permanently delete a task list and every task in it. Confirm with the user first."""
    tl = _resolve_list(task_list)
    _call(service().tasklists().delete(tasklist=tl["id"]))
    _refresh_menu_bar()
    return {"deleted": tl["title"], "id": tl["id"]}


# --------------------------------------------------------------------------- task tools


@mcp.tool(annotations=READ_ONLY)
def list_tasks(
    task_list: str | None = None,
    include_completed: bool = False,
    due_on_or_after: str | None = None,
    due_on_or_before: str | None = None,
) -> dict:
    """List tasks in one list, with subtasks nested under their parents.

    task_list: title or id; omit for the default list.
    due_on_or_after / due_on_or_before: optional YYYY-MM-DD bounds (inclusive).
    """
    tl = _resolve_list(task_list)
    tasks = _fetch_tasks(tl["id"], include_completed, due_on_or_after, due_on_or_before)
    return {"list": tl["title"], "list_id": tl["id"], "tasks": _tree(tasks)}


@mcp.tool(annotations=READ_ONLY)
def list_all_tasks(
    include_completed: bool = False,
    due_on_or_before: str | None = None,
) -> list[dict]:
    """Everything across all lists, grouped by list. Use for "what's on my plate".

    due_on_or_before: optional YYYY-MM-DD to only show tasks due by that date (undated tasks are excluded when set).
    """
    out = []
    for tl in _all_lists():
        tasks = _fetch_tasks(tl["id"], include_completed, None, due_on_or_before)
        if tasks:
            out.append({"list": tl["title"], "list_id": tl["id"], "tasks": _tree(tasks)})
    return out


@mcp.tool(annotations=READ_ONLY)
def search_tasks(query: str, include_completed: bool = False) -> list[dict]:
    """Case-insensitive search of task titles and notes across all lists."""
    q = query.lower()
    hits = []
    for tl in _all_lists():
        for t in _fetch_tasks(tl["id"], include_completed):
            if q in t.get("title", "").lower() or q in t.get("notes", "").lower():
                hits.append({**_fmt_task(t), "list": tl["title"], "list_id": tl["id"]})
    return hits


@mcp.tool(annotations=WRITE)
def create_task(
    title: str,
    task_list: str | None = None,
    notes: str | None = None,
    due: str | None = None,
    parent_task_id: str | None = None,
) -> dict:
    """Create a task. Pass parent_task_id to make it a subtask (one level deep only).

    task_list: title or id; omit for the default list. The list must exist (see create_task_list).
    due: YYYY-MM-DD. Google Tasks stores dates only, no time of day.
    New tasks go to the top of the list (or of the parent's subtasks).
    """
    tl = _resolve_list(task_list)
    body: dict[str, Any] = {"title": title}
    if notes:
        body["notes"] = notes
    if due:
        body["due"] = _due_to_api(due)
    kwargs: dict[str, Any] = {"tasklist": tl["id"], "body": body}
    if parent_task_id:
        kwargs["parent"] = parent_task_id
    t = _call(service().tasks().insert(**kwargs))
    _refresh_menu_bar()
    return {**_fmt_task(t), "list": tl["title"], "list_id": tl["id"]}


@mcp.tool(annotations=WRITE)
def update_task(
    task_id: str,
    task_list: str | None = None,
    title: str | None = None,
    notes: str | None = None,
    due: str | None = None,
    clear_due: bool = False,
    completed: bool | None = None,
) -> dict:
    """Update fields on a task. Only the fields you pass change.

    completed=True marks it done, completed=False reopens it. clear_due=True removes the due date.
    """
    tl = _resolve_list(task_list)
    body: dict[str, Any] = {}
    if title is not None:
        body["title"] = title
    if notes is not None:
        body["notes"] = notes
    if clear_due:
        body["due"] = None
    elif due is not None:
        body["due"] = _due_to_api(due)
    if completed is True:
        body["status"] = "completed"
    elif completed is False:
        body["status"] = "needsAction"
        body["completed"] = None
    if not body:
        raise ToolError("Nothing to update.")
    t = _call(service().tasks().patch(tasklist=tl["id"], task=task_id, body=body))
    _refresh_menu_bar()
    return {**_fmt_task(t), "list": tl["title"]}


@mcp.tool(annotations=WRITE)
def complete_task(task_id: str, task_list: str | None = None) -> dict:
    """Mark a task as done."""
    return update_task(task_id=task_id, task_list=task_list, completed=True)


@mcp.tool(annotations=WRITE)
def move_task(
    task_id: str,
    task_list: str | None = None,
    parent_task_id: str | None = None,
    after_task_id: str | None = None,
    destination_list: str | None = None,
) -> dict:
    """Reorder a task, make it a subtask of another, promote it to top level, or move it to another list.

    parent_task_id: new parent (omit to make it top-level).
    after_task_id: sibling to place it after (omit to put it first).
    destination_list: title or id of another list to move it into.
    """
    tl = _resolve_list(task_list)
    kwargs: dict[str, Any] = {"tasklist": tl["id"], "task": task_id}
    if parent_task_id:
        kwargs["parent"] = parent_task_id
    if after_task_id:
        kwargs["previous"] = after_task_id
    dest = tl
    if destination_list:
        dest = _resolve_list(destination_list)
        if dest["id"] != tl["id"]:
            kwargs["destinationTasklist"] = dest["id"]
    t = _call(service().tasks().move(**kwargs))
    _refresh_menu_bar()
    return {**_fmt_task(t), "list": dest["title"], "list_id": dest["id"]}


@mcp.tool(annotations=DESTRUCTIVE)
def delete_task(task_id: str, task_list: str | None = None) -> dict:
    """Permanently delete a task (and its subtasks). Prefer complete_task unless the user asked to delete."""
    tl = _resolve_list(task_list)
    _call(service().tasks().delete(tasklist=tl["id"], task=task_id))
    _refresh_menu_bar()
    return {"deleted": task_id, "list": tl["title"]}


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "auth":
        run_auth()
    elif len(sys.argv) > 1 and sys.argv[1] == "check":
        run_check()
    elif len(sys.argv) > 1 and sys.argv[1] == "bridge-init":
        bridge_init()
    elif len(sys.argv) > 2 and sys.argv[1] == "bridge-url":
        bridge_url(sys.argv[2])
    else:
        mcp.run()
