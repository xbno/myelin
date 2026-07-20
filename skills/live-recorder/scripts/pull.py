#!/usr/bin/env python3
"""Incremental pulls from a live-recorder transcript (JSONL).

Each invocation emits only lines not yet seen (persistent cursor per file),
so Claude can poll during a live call without re-reading context it already
has. Zero dependencies.

Transcript lines look like:
  {"ts":"…","source":"mic|system","speaker":"S1","t0":12.34,"t1":15.60,"text":"…"}
"""

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

# Default under the user's project folder (not ~/Library, a macOS-protected
# path sandboxed agents like Cowork can't mount). Override with $LIVE_RECORDER_DIR.
DEFAULT_DIR = Path(
    os.environ.get("LIVE_RECORDER_DIR") or (Path.home() / "ml/myelin/recordings")
).expanduser()
SKILL_DIR = Path(__file__).resolve().parent.parent


def write_state(state_file: Path, cursor: int, session: str) -> None:
    """Atomically persist the cursor: write a temp file then os.replace (an
    atomic rename on POSIX). No lock needed — each session owns its own state
    file, so there is a single writer, and the rename can't leave a torn file
    even if the process dies mid-write."""
    tmp = state_file.with_name(f"{state_file.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps({"cursor": cursor, "session": session, "updated_at": time.time()}))
    os.replace(tmp, state_file)


def session_key(explicit: str | None) -> str:
    """Identify the calling Claude session so each one keeps its own cursor.
    Falls back through --session, the harness env var, then 'shared' (the old
    single-cursor behavior) so a plain shell still works."""
    sid = explicit or os.environ.get("CLAUDE_CODE_SESSION_ID") or os.environ.get(
        "CLAUDE_SESSION_ID"
    )
    if not sid:
        return "shared"
    # keep filenames tame regardless of what the id looks like
    return re.sub(r"[^A-Za-z0-9_-]", "", sid)[:40] or "shared"


def newest_transcript(directory: Path) -> Path | None:
    files = sorted(directory.glob("*.jsonl"), key=lambda p: p.stat().st_mtime)
    return files[-1] if files else None


def fmt_time(t0, base):
    if t0 is None:
        return "?:??"
    rel = max(0.0, t0 - base)
    return f"{int(rel // 60)}:{int(rel % 60):02d}"


def label(line: dict) -> str:
    if line.get("source") == "mic":
        return "Me"
    return line.get("speaker") or "Them"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--file", help="transcript .jsonl (default: newest in default dir)")
    ap.add_argument("--dir", default=str(DEFAULT_DIR), help="transcript directory to search")
    ap.add_argument("--list", action="store_true", help="list transcripts and exit")
    ap.add_argument("--reset", action="store_true", help="zero the cursor and exit")
    ap.add_argument(
        "--full",
        action="store_true",
        help="print the whole transcript from the top (ignores the cursor), then "
        "continue incrementally from the end on the next pull",
    )
    ap.add_argument("--state-dir", default=str(SKILL_DIR / "state"), help="cursor storage dir")
    ap.add_argument(
        "--session",
        help="cursor namespace (default: this Claude session, so parallel "
        "sessions each get the full stream instead of splitting it)",
    )
    args = ap.parse_args()

    session = session_key(args.session)

    directory = Path(args.dir).expanduser()

    if args.list:
        files = sorted(directory.glob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
        if not files:
            print(f"no transcripts in {directory}")
            return 0
        for p in files[:10]:
            mtime = time.strftime("%Y-%m-%d %H:%M", time.localtime(p.stat().st_mtime))
            n = sum(1 for _ in p.open())
            print(f"{mtime}  {n:4d} lines  {p.name}")
        return 0

    path = Path(args.file).expanduser() if args.file else newest_transcript(directory)
    if path is None or not path.exists():
        print(f"no transcript found (searched {directory}); is the recorder running?")
        return 1

    state_dir = Path(args.state_dir).expanduser()
    state_dir.mkdir(parents=True, exist_ok=True)
    state_file = state_dir / f"{path.stem}.{session}.json"

    cursor = 0
    if state_file.exists():
        try:
            cursor = json.loads(state_file.read_text()).get("cursor", 0)
        except (json.JSONDecodeError, OSError):
            cursor = 0

    if args.reset:
        write_state(state_file, 0, session)
        print(f"cursor reset for {path.name} (session {session})")
        return 0

    if args.full:
        cursor = 0  # re-emit everything from the top; cursor advances to end below

    raw_lines = path.read_text().splitlines()
    lines = []
    for raw in raw_lines:
        raw = raw.strip()
        if not raw:
            continue
        try:
            lines.append(json.loads(raw))
        except json.JSONDecodeError:
            continue  # possibly a torn tail write; next pull picks it up

    total = len(lines)
    if total < cursor:
        print(f"transcript shrank ({total} < cursor {cursor}) — starting over")
        cursor = 0

    base = next((l.get("t0") for l in lines if l.get("t0") is not None), 0.0) or 0.0
    new = lines[cursor:]

    if not new:
        print(f"no new segments (still {total}) — {path.name}")
        return 0

    print(f"{path.name} — segments {cursor + 1}–{total} of {total}")
    for line in new:
        text = (line.get("text") or "").strip()
        if not text:
            continue
        print(f"**{label(line)} ({fmt_time(line.get('t0'), base)}):** {text}")

    write_state(state_file, total, session)
    return 0


if __name__ == "__main__":
    sys.exit(main())
