"""The menu bar refresh must only poke a SwiftBar that is already running.

`open -g swiftbar://refreshplugin?...` launches SwiftBar when it is not running, and SwiftBar
2.1.1 traps (Trace/BPT) handling that URL before its plugins are loaded. So a write from Claude
while SwiftBar was down used to crash it on every attempt instead of bringing it up.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import server  # noqa: E402


def _capture_open(monkeypatch, running: bool) -> list[list[str]]:
    calls: list[list[str]] = []
    monkeypatch.setattr(server.sys, "platform", "darwin")
    monkeypatch.delenv("GTASKS_NO_REFRESH", raising=False)
    monkeypatch.setattr(server, "_swiftbar_running", lambda: running)
    monkeypatch.setattr(
        server.subprocess, "run",
        lambda argv, *a, **k: calls.append(list(argv)) or subprocess.CompletedProcess(argv, 0),
    )
    return calls


def test_refresh_pokes_a_running_swiftbar(monkeypatch):
    calls = _capture_open(monkeypatch, running=True)
    server._refresh_menu_bar()
    assert calls == [["open", "-g", "swiftbar://refreshplugin?plugin=gtasks.5m.py"]]


def test_refresh_never_launches_swiftbar(monkeypatch):
    calls = _capture_open(monkeypatch, running=False)
    server._refresh_menu_bar()
    assert calls == []
