---
name: live-recorder
description: Stream the transcript of an active local recording (live-recorder) into context incrementally. Each pull returns only what's new since the last pull. Use when the user says "pull the live call", "what's happening in my meeting", wants running notes/research during a call recorded with the local recorder, or asks to start/stop a recording.
---

# live-recorder: incremental pulls from the local call recorder

The `recorder` CLI transcribes the user's meetings fully on-device (mic +
system audio → Apple SpeechAnalyzer) into an append-only JSONL file. This
skill pulls that transcript a delta at a time: a cursor is kept per file, so
each run prints only lines you haven't seen — safe to poll in a loop.

## Start / stop a recording

```bash
recorder                 # records until Ctrl-C; prints transcript path
recorder --help          # flags: --out FILE, --locale, --mic-only, --system-only
```

If `recorder` is not on PATH, build/install it from the repo: `cd recorder && make install`.

## Sandboxed session (Cowork)? Attach the folder FIRST

Recordings live on the user's Mac at `~/ml/myelin/recordings`. Inside
a Cowork VM that folder does **not exist until attached** — so attaching is
**step 1, before any pull** (skip only if the session already has it, e.g.
opened via the recorder's ⌥⌘C hotkey, which pre-attaches it). Request access
to `~/ml/myelin` with the folder-access tool; its response prints the
connected path. From then on always pull with that path pinned:

```bash
LIVE_RECORDER_DIR=<connected-path>/recordings python3 <skill-dir>/scripts/pull.py
```

Never run a pull before the folder is attached, and never retry a failed
pull without attaching first.

## Pull the transcript (the main loop)

```bash
python3 <skill-dir>/scripts/pull.py
```

`<skill-dir>` is this skill's base directory — announced when the skill
loads. Don't assume `~/.claude/skills/live-recorder`: project installs and
Cowork sessions place the skill elsewhere. Always invoke via `python3` —
skill mounts are often noexec, so running the script directly fails with
"Permission denied".

- Auto-selects the **newest** transcript in the recordings dir:
  `$LIVE_RECORDER_DIR` if set, else `~/ml/myelin/recordings/`, else the
  Cowork-session mounts (`~/mnt/**/recordings`, or the folder's original
  `/Users/<user>/…` path). In a Cowork session the recordings folder (or the
  repo containing it) must be **attached to the session** for any of this to
  be visible.
- Output: header `<file> — segments 5–12 of 12`, then one
  `**Me (m:ss):** …` / `**Them (m:ss):** …` line per new segment
  (`**S1/S2 (m:ss):**` once diarization is on — mic is always Me).
- `no new segments (still N)` → nothing new; wait (e.g. `sleep 30`) and pull
  again. Polling every 20–60s during a call is plenty.
- `transcript shrank … starting over` → file was replaced; re-streams from
  the top.

Flags: `--list` (recent transcripts), `--file <path>` (pin one),
`--reset` (zero cursor), `--dir`, `--state-dir`.

**Full transcript / re-read:** when the user says "full transcript", "reread",
"pull the whole thing", "start over", or "catch me up from the top", run
`scripts/pull.py --full`. It prints the entire transcript from segment 1
(ignoring the cursor), then advances the cursor to the end so plain "pull"
resumes incrementally afterward.

## Workflow (context-efficient — read this)

Invoke this skill **once** at the start of a call (e.g. `/live-recorder keep
running notes`). **Never re-invoke it** during the call — just re-run
`scripts/pull.py`; the instructions are already in context.

**Pull before answering:** while a recording is live, run `scripts/pull.py`
before answering **any** user message — even one that doesn't mention the
call. The transcript is the shared context of the conversation the user is
in right now; every answer should reflect what was just said, without the
user having to ask for a pull.

Because pulls happen automatically before every answer, **never tell the
user to say "pull"** / "anything new?" or otherwise coach them to ask for
updates — that's obsolete. Just answer.

The only thing that grows context on each pull is the new transcript text,
and the cursor already keeps that minimal (never re-sends seen lines). On long
calls, keep a **rolling summary**: after each pull, fold the new lines into a
short running-notes block and rely on that, so the raw lines can age out of
context rather than accumulating.

## Notes

- Everything is local: capture, ASR, diarization, transcript. Nothing leaves
  the machine.
- Mic lines are the user ("Me"); system-audio lines are everyone else,
  diarized into S1/S2/… — or real names for voices enrolled via samples in
  `speakers/` inside the recordings dir (e.g. `Alice.wav`).
- If the user asks you to take notes / research topics live, poll, then act
  on the new lines each cycle; don't re-summarize what you already covered.
- Cursor is per-session per-call (keyed by `CLAUDE_CODE_SESSION_ID`): two
  Claude sessions pulling the same call each get the full stream
  independently, not disjoint halves. Override with `--session <name>` to
  share or separate cursors deliberately.

## Requirements

macOS 26+, `recorder` installed, first-run permission prompts approved
(system-audio recording + microphone for the terminal running it).
