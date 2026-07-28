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
import tempfile
import time
from pathlib import Path

# Default under the user's project folder (not ~/Library, a macOS-protected
# path sandboxed agents like Cowork can't mount). Override with $LIVE_RECORDER_DIR.
def default_dir() -> Path:
    env = os.environ.get("LIVE_RECORDER_DIR")
    if env:
        return Path(env).expanduser()
    home = Path.home()
    candidates = [home / "ml/myelin/recordings", home / "recordings"]
    # Cowork/VM sessions: home is /sessions/<name>; folders attached to the
    # session mount under ~/mnt (by basename — connecting the myelin repo
    # gives ~/mnt/myelin/recordings) and are often also exposed at their
    # original Mac /Users/<user>/ path. Cover all of these.
    for pattern in (
        (home, "mnt/recordings"),
        (home, "mnt/*/recordings"),
        (home, "mnt/*/*/recordings"),
        (Path("/Users"), "*/ml/myelin/recordings"),
    ):
        try:  # VM mounts can raise OSError mid-iteration; skip, don't crash
            candidates += sorted(pattern[0].glob(pattern[1]))
        except OSError:
            continue
    for c in candidates:
        if c.is_dir():
            return c
    return candidates[0]


DEFAULT_DIR = default_dir()
SKILL_DIR = Path(__file__).resolve().parent.parent

# Cap stdout per run: oversized tool output gets offloaded by the harness to
# a host-side tool-results file that sandboxed (Cowork) sessions can't read
# ("File is outside allowed folders"). Stay safely under that threshold; the
# cursor only advances past what was actually printed, so nothing is lost —
# the next run continues where this one stopped.
MAX_CHARS = 25_000


def write_state(state_file: Path | None, cursor: int, session: str) -> None:
    """Atomically persist the cursor: write a temp file then os.replace (an
    atomic rename on POSIX). No lock needed — each session owns its own state
    file, so there is a single writer, and the rename can't leave a torn file
    even if the process dies mid-write.

    Never raises: a cursor that can't be saved must not fail the pull (the
    transcript was already printed) — warn and carry on; the next pull just
    repeats these lines."""
    if state_file is None:
        return
    try:
        tmp = state_file.with_name(f"{state_file.name}.{os.getpid()}.tmp")
        tmp.write_text(
            json.dumps({"cursor": cursor, "session": session, "updated_at": time.time()})
        )
        os.replace(tmp, state_file)
    except OSError as e:
        print(f"warning: cursor not saved ({e}) — next pull may repeat lines", file=sys.stderr)


def read_pin(pin_file: Path | None) -> Path | None:
    """Which transcript this session last pulled. Without this, an implicit
    (no --file) pull always follows the *newest* file in the dir — so if the
    user stops recording call A and starts call B, the very next plain pull
    silently jumps to B's transcript mid-conversation about A."""
    if pin_file is None or not pin_file.exists():
        return None
    try:
        p = json.loads(pin_file.read_text()).get("path")
        return Path(p) if p else None
    except (json.JSONDecodeError, OSError):
        return None


def write_pin(pin_file: Path | None, path: Path) -> None:
    if pin_file is None:
        return
    try:
        tmp = pin_file.with_name(f"{pin_file.name}.{os.getpid()}.tmp")
        tmp.write_text(json.dumps({"path": str(path)}))
        os.replace(tmp, pin_file)
    except OSError:
        pass  # non-fatal — worst case the next pull re-pins


def writable_dir(candidates) -> Path | None:
    """First candidate directory we can actually write to (probe write — a
    dir can exist but be unwritable, e.g. /tmp/<dir> owned by another user in
    a sandboxed VM)."""
    for cand in candidates:
        if not cand:
            continue
        d = Path(cand).expanduser()
        try:
            d.mkdir(parents=True, exist_ok=True)
            probe = d / f".probe.{os.getpid()}"
            probe.write_text("")
            probe.unlink()
            return d
        except OSError:
            continue
    return None


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


def safe_mtime(p: Path) -> float:
    try:
        return p.stat().st_mtime
    except OSError:  # ghost entries happen on VM mounts
        return 0.0


def newest_transcript(directory: Path) -> Path | None:
    try:
        files = sorted(directory.glob("*.jsonl"), key=safe_mtime)
    except OSError:
        return None
    return files[-1] if files else None


def label(line: dict) -> str:
    if line.get("source") == "mic":
        return "Me"
    return line.get("speaker") or "Them"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--file",
        help="transcript .jsonl (default: this session's pinned file, or the "
        "newest in --dir if nothing is pinned yet)",
    )
    ap.add_argument("--dir", default=str(DEFAULT_DIR), help="transcript directory to search")
    ap.add_argument("--list", action="store_true", help="list transcripts and exit")
    ap.add_argument("--reset", action="store_true", help="zero the cursor and exit")
    ap.add_argument(
        "--unpin",
        action="store_true",
        help="forget this session's pinned transcript and exit; the next plain "
        "pull auto-selects the newest file again (use after intentionally "
        "switching to a different call in the same session)",
    )
    ap.add_argument(
        "--full",
        action="store_true",
        help="print the whole transcript from the top (ignores the cursor), then "
        "continue incrementally from the end on the next pull",
    )
    ap.add_argument(
        "--state-dir",
        help="cursor storage dir (default: first writable of skill dir, "
        "~/.cache/live-recorder, tempdir)",
    )
    ap.add_argument(
        "--session",
        help="cursor namespace (default: this Claude session, so parallel "
        "sessions each get the full stream instead of splitting it)",
    )
    args = ap.parse_args()

    session = session_key(args.session)

    directory = Path(args.dir).expanduser()

    if args.list:
        files = sorted(directory.glob("*.jsonl"), key=safe_mtime, reverse=True)
        if not files:
            print(f"no transcripts in {directory}")
            return 0
        for p in files[:10]:
            mtime = time.strftime("%Y-%m-%d %H:%M", time.localtime(p.stat().st_mtime))
            n = sum(1 for _ in p.open())
            print(f"{mtime}  {n:4d} lines  {p.name}")
        return 0

    # An unwritable state dir must not fail the pull (e.g. Cowork's VM: the
    # mounted skill dir or /tmp can be read-only / other-owned) — fall back.
    state_dir = writable_dir([
        args.state_dir,
        SKILL_DIR / "state",
        Path.home() / ".cache/live-recorder",
        Path(tempfile.gettempdir()) / f"live-recorder-{os.getuid()}",
    ])
    if state_dir is None:
        print("warning: no writable state dir — every pull will print from the top", file=sys.stderr)
    pin_file = state_dir / f"pinned.{session}.json" if state_dir else None
    pinned = read_pin(pin_file)

    if args.unpin:
        if pin_file is not None and pin_file.exists():
            try:
                pin_file.unlink()
            except OSError:
                pass
        print(f"unpinned (session {session}) — next pull auto-selects the newest transcript")
        return 0

    if args.file:
        path = Path(args.file).expanduser()
        if pinned != path:
            write_pin(pin_file, path)
            print(f"pinned {path.name} for this session (--unpin to follow the newest transcript again)")
    elif pinned is not None and pinned.exists():
        path = pinned
    else:
        path = newest_transcript(directory)
        if path is not None:
            if pinned is not None:
                print(f"previously pinned transcript is gone — re-pinning to {path.name}")
            else:
                print(f"pinned {path.name} for this session (--unpin to follow the newest transcript again)")
            write_pin(pin_file, path)

    if path is None or not path.exists():
        print(f"no transcript found (searched {directory}); is the recorder running?")
        print(
            "if this is a sandboxed session: ATTACH the recordings folder to the "
            "session first (folder-access tool, e.g. ~/ml/myelin) — it does "
            "not exist inside the VM until attached. Do NOT retry without attaching."
        )
        return 1

    state_file = state_dir / f"{path.stem}.{session}.json" if state_dir else None

    cursor = 0
    if state_file is not None and state_file.exists():
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

    raw_lines = path.read_text(errors="replace").splitlines()
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

    new = lines[cursor:]

    if not new:
        print(f"no new segments (still {total}) — {path.name}")
        return 0

    # Consecutive segments from the same speaker label merge into one block.
    # Diarization labels are unreliable (one label often spans several real
    # people), so a silence gap ≥ GAP_BREAK also starts a new block — it's the
    # strongest turn-change signal we have besides the label itself.
    GAP_BREAK = 3.0

    out, used, consumed = [], 0, 0
    last_label, last_t1 = None, None
    for line in new:
        text = (line.get("text") or "").strip()
        if not text:
            consumed += 1  # nothing to print; just advance past it
            continue
        lab = label(line)
        t0, t1 = line.get("t0"), line.get("t1")
        gap = t0 - last_t1 if t0 is not None and last_t1 is not None else None
        merge = bool(out) and lab == last_label and (gap is None or gap < GAP_BREAK)
        added = len(text) + 1 if merge else len(f"**{lab}:** {text}") + 1
        if out and used + added > MAX_CHARS:
            break
        if merge:
            out[-1] += " " + text
        else:
            out.append(f"**{lab}:** {text}")
        used += added
        last_label = lab
        if t1 is not None:
            last_t1 = t1
        consumed += 1

    print(f"{path.name} — segments {cursor + 1}–{cursor + consumed} of {total}")
    for s in out:
        print(s)
    remaining = total - (cursor + consumed)
    if remaining:
        print(f"(output capped — {remaining} more segments; run again to continue)")

    write_state(state_file, cursor + consumed, session)
    return 0


if __name__ == "__main__":
    sys.exit(main())
