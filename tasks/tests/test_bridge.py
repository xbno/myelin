"""End-to-end over HTTP: server.py -> urllib -> fake Apps Script web app -> the real Code.gs under Node.

The fake web app mimics Apps Script's behavior: POST /exec answers 302 to a one-time URL,
and the client's follow-up GET receives the JSON. Skipped if `node` is not installed.

Run: uv run --group dev pytest -q
"""

from __future__ import annotations

import http.server
import json
import shutil
import subprocess
import sys
import threading
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import server  # noqa: E402

pytestmark = pytest.mark.skipif(shutil.which("node") is None, reason="node not installed")
SECRET = "test-secret"


@pytest.fixture
def bridge(tmp_path, monkeypatch):
    state = tmp_path / "state.json"
    results: dict[str, bytes] = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            out = subprocess.run(
                ["node", str(ROOT / "tests" / "apps_script_harness.js"), str(ROOT / "apps_script" / "Code.gs"), str(state), SECRET],
                input=body, capture_output=True, check=True,
            ).stdout
            key = str(len(results))
            results[key] = out
            self.send_response(302)
            self.send_header("Location", f"/echo?id={key}")
            self.end_headers()

        def do_GET(self):
            key = self.path.split("id=")[-1]
            out = results.pop(key, b'{"error":"bad echo"}')
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(out)

    httpd = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    cfg = tmp_path / "bridge.json"
    cfg.write_text(json.dumps({"url": f"http://127.0.0.1:{httpd.server_port}/exec", "secret": SECRET}))
    monkeypatch.setattr(server, "BRIDGE_FILE", cfg)
    monkeypatch.setattr(server, "TOKEN_FILE", tmp_path / "no-token.json")  # force the bridge backend
    server.set_service(None)
    yield cfg
    server.set_service(None)
    httpd.shutdown()


def test_full_flow_through_code_gs(bridge):
    assert server.bridge_call("ping")["user"] == "user@example.com"

    assert server.create_task_list("Acme")["created"] is True
    parent = server.create_task("Kickoff", task_list="Acme", due="2026-09-24", notes="bring the contract")
    sub = server.create_task("Draft agenda", task_list="Acme", parent_task_id=parent["id"])
    tree = server.list_tasks("Acme")["tasks"]
    assert tree[0]["title"] == "Kickoff" and tree[0]["due"] == "2026-09-24"
    assert tree[0]["subtasks"][0]["id"] == sub["id"]

    # Clearing a due date sends null, which Code.gs must turn into a full update.
    cleared = server.update_task(parent["id"], task_list="Acme", clear_due=True)
    assert "due" not in cleared

    server.complete_task(sub["id"], task_list="Acme")
    assert all(t["id"] != sub["id"] for t in server.list_tasks("Acme")["tasks"][0].get("subtasks", []))
    reopened = server.update_task(sub["id"], task_list="Acme", completed=False)
    assert reopened["status"] == "needsAction" and "completed_at" not in reopened

    server.create_task_list("Globex")
    t = server.create_task("Send invoice", due="2026-09-24")
    assert server.move_task(t["id"], destination_list="Globex")["list"] == "Globex"
    assert [h["list"] for h in server.search_tasks("send invoice")] == ["Globex"]
    assert {g["list"] for g in server.list_all_tasks(due_on_or_before="2026-09-25")} == {"Globex"}

    server.delete_task(t["id"], task_list="Globex")
    server.delete_task_list("Globex")
    assert [l["title"] for l in server.list_task_lists()] == ["My Tasks", "Acme"]


def test_wrong_secret_is_rejected(bridge):
    cfg = json.loads(bridge.read_text())
    cfg["secret"] = "nope"
    with pytest.raises(server.ToolError, match="Unauthorized"):
        server.bridge_call("tasklists.list", cfg=cfg)


def test_missing_config_gives_setup_hint(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "BRIDGE_FILE", tmp_path / "missing.json")
    monkeypatch.setattr(server, "TOKEN_FILE", tmp_path / "no-token.json")
    server.set_service(None)
    with pytest.raises(server.ToolError, match="bridge-init"):
        server.list_task_lists()
