#!/usr/bin/env python3
# <swiftbar.title>Google Tasks</swiftbar.title>
# <swiftbar.desc>Open Google Tasks grouped by list. Click a task to complete it.</swiftbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
"""SwiftBar plugin for Google Tasks. Reuses server.py and its credentials (token.json or bridge.json).

The ".5m." in the filename tells SwiftBar to refresh every 5 minutes.
Clicking a task runs `complete <list_id> <task_id>`. Tasks with notes get a 🔗 row whose submenu shows the notes and clickable links.
SwiftBar starts this with the system python3; it re-runs itself with the project's .venv python, which has the dependencies.
Optional colors.json next to bridge.json picks colors per list: {"list title": ["#hex", "38;5;N"]}.
"""

from __future__ import annotations

import json
import os
import re
import sys
import textwrap
from datetime import date, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VENV = ROOT / ".venv"
if Path(sys.prefix).resolve() != VENV.resolve() and (VENV / "bin" / "python").exists():
    os.execv(str(VENV / "bin" / "python"), [str(VENV / "bin" / "python"), str(Path(__file__).resolve()), *sys.argv[1:]])
sys.path.insert(0, str(ROOT))

import server  # noqa: E402

TASKS_URL = "https://tasks.google.com"

# Global hotkey that opens this menu (SwiftBar "shortcut" on the header line).
HOTKEY = "CMD+OPTION+T"

# Per-list colors: (hex for the header, ANSI 256-color code for the task bullets). Soft/pastel tones.
# Lists named in colors.json get their own color; the rest pick one of these by title.
FALLBACK_COLORS = [("#5AA9B5", "38;5;73"), ("#C98BA6", "38;5;175"), ("#A8A060", "38;5;143"), ("#8C8C8C", "38;5;245")]

# Due-date colors: today/overdue red, tomorrow dark yellow, later gray.
DUE_RED = "1;38;5;160"
DUE_YELLOW = "38;5;136"
DUE_GRAY = "38;5;245"

ESC = "\x1b["
RESET = ESC + "0m"


def _load_list_colors() -> dict[str, tuple[str, str]]:
    try:
        raw = json.loads((server.HOME / "colors.json").read_text())
        return {k.strip().lower(): (v[0], v[1]) for k, v in raw.items()}
    except (OSError, ValueError, IndexError, TypeError, AttributeError):
        return {}


LIST_COLORS = _load_list_colors()


def _color_for(title: str) -> tuple[str, str]:
    key = title.strip().lower()
    if key in LIST_COLORS:
        return LIST_COLORS[key]
    return FALLBACK_COLORS[sum(map(ord, key)) % len(FALLBACK_COLORS)]


def _clean(s: str) -> str:
    # SwiftBar splits on "|" and treats a leading "--" as a submenu marker.
    return s.replace("|", "∣").replace("\n", " ").lstrip("-").strip() or "(untitled)"


URL_RE = re.compile(r"(https?://[^\s)\]>,;]+|\b(?:[\w-]+\.)+(?:com|io|org|dev|net|ai|so)/[^\s)\]>,;]*)")


def _links(text: str) -> list[str]:
    out = []
    for m in URL_RE.findall(text or ""):
        url = m.rstrip(".")
        if not url.startswith("http"):
            url = "https://" + url
        if url not in out:
            out.append(url)
    return out


def _details(item: dict, depth: int) -> list[str]:
    """For tasks with notes: a small "notes & links" row under the task whose submenu holds
    the full notes and clickable links. The task row itself stays a one-click complete."""
    notes = item.get("notes") or ""
    if not notes:
        return []
    indent = "      " if depth else "   "
    links = _links(notes)
    label = "notes & links" if links else "notes"
    out = [f"{indent}🔗 {label} | size=11 color=#8e8e93"]
    for para in notes.splitlines():
        for chunk in textwrap.wrap(para, 80) or [""]:
            out.append(f"--{_clean(chunk)} | size=12 color=#8e8e93")
    if links:
        out.append("-----")
        for url in links:
            out.append(f"--🔗 {_clean(url)} | href={url} size=12")
    return out


def _due(due: str | None, today: date) -> tuple[str, str, bool]:
    """(label, ansi color code, counts as due-now)."""
    if not due:
        return "", "", False
    d = date.fromisoformat(due[:10])
    stamp = f"{d:%a %-m/%-d}"
    if d < today:
        return f"{stamp} · overdue", DUE_RED, True
    if d == today:
        return f"{stamp} · today", DUE_RED, True
    if d == today + timedelta(days=1):
        return f"{stamp} · tomorrow", DUE_YELLOW, False
    return stamp, DUE_GRAY, False


def _next_due(tasks: list[dict], today: date) -> str:
    dues = sorted(t["due"] for t in tasks if t.get("due"))
    if not dues:
        return ""
    label, _, _ = _due(dues[0], today)
    return label.split(" · ")[-1] if " · " in label else label


def render(today: date | None = None) -> str:
    today = today or date.today()
    script = Path(__file__).resolve()
    groups = []
    try:
        for tl in server._all_lists():
            tasks = server._tree(server._fetch_tasks(tl["id"], include_completed=False))
            if tasks:
                groups.append((tl, tasks))
    except Exception as e:  # noqa: BLE001 - show any failure in the menu bar
        return "\n".join([
            f"Tasks ⚠ | sfimage=checklist shortcut={HOTKEY}",
            "---",
            f"{_clean(str(e))[:120]} | color=red",
            f"Setup: see {ROOT / 'README.md'} | size=11",
            "Refresh | refresh=true",
        ])

    total = sum(1 + len(t.get("subtasks", [])) for _, ts in groups for t in ts)
    urgent = 0
    body: list[str] = []
    for tl, tasks in groups:
        hexcolor, ansi = _color_for(tl["title"])
        count = sum(1 + len(t.get("subtasks", [])) for t in tasks)
        nxt = _next_due(tasks, today)
        meta = f"{count} open" + (f" · next {nxt}" if nxt else "")
        body.append("---")
        body.append(
            f"{_clean(tl['title'])}   {meta} | color={hexcolor} size=13 href={TASKS_URL}"
        )
        for t in tasks:
            for depth, item in [(0, t)] + [(1, s) for s in t.get("subtasks", [])]:
                label, due_ansi, hot = _due(item.get("due"), today)
                urgent += hot
                bullet = f"{ESC}{ansi}m{'  ↳ ○' if depth else '●'}{RESET}"
                due_txt = f"   {ESC}{due_ansi}m{label}{RESET}" if label else ""
                body.append(
                    f"{bullet} {_clean(item['title'])}{due_txt} | ansi=true "
                    f"bash={script} param1=complete param2={tl['id']} param3={item['id']} "
                    "terminal=false refresh=true"
                )
                body.extend(_details(item, depth))

    title = f"{urgent} due" if urgent else (str(total) if total else "✓")
    lines = [f"{title} | sfimage=checklist shortcut={HOTKEY}"]
    lines.extend(body if body else ["---", "Nothing open | color=#8e8e93"])
    lines += [
        "---",
        "Click a task to complete it · 🔗 rows open notes and links | size=11 color=#8e8e93",
        f"Open Google Tasks | href={TASKS_URL}",
        "Refresh | refresh=true",
    ]
    return "\n".join(lines)


def main(argv: list[str]) -> None:
    if len(argv) >= 4 and argv[1] == "complete":
        server._call(server.service().tasks().patch(tasklist=argv[2], task=argv[3], body={"status": "completed"}))
        return
    print(render())


if __name__ == "__main__":
    main(sys.argv)
