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

## Pull the transcript (the main loop)

```bash
~/.claude/skills/live-recorder/scripts/pull.py
```

- Auto-selects the **newest** transcript in
  `~/ml/myelin/recordings/` (override with `$LIVE_RECORDER_DIR`).
- Output: header `<file> — segments 5–12 of 12`, then one
  `**Me (m:ss):** …` / `**Them (m:ss):** …` line per new segment
  (`**S1/S2 (m:ss):**` once diarization is on — mic is always Me).
- `no new segments (still N)` → nothing new; wait (e.g. `sleep 30`) and pull
  again. Polling every 20–60s during a call is plenty.
- `transcript shrank … starting over` → file was replaced; re-streams from
  the top.

Flags: `--list` (recent transcripts), `--file <path>` (pin one),
`--reset` (zero cursor), `--dir`, `--state-dir`.

## Workflow (context-efficient — read this)

Invoke this skill **once** at the start of a call (e.g. `/live-recorder keep
running notes`). After that, when the user says "pull" / "more" / "anything
new?" / "catch up", **do not re-invoke the skill** — just re-run
`scripts/pull.py` again. The instructions are already in context; re-invoking
would reload this file for nothing.

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
  `~/ml/myelin/recordings/speakers/` (e.g. `Alice.wav`).
- If the user asks you to take notes / research topics live, poll, then act
  on the new lines each cycle; don't re-summarize what you already covered.
- Cursor is per-session per-call (keyed by `CLAUDE_CODE_SESSION_ID`): two
  Claude sessions pulling the same call each get the full stream
  independently, not disjoint halves. Override with `--session <name>` to
  share or separate cursors deliberately.

## Requirements

macOS 26+, `recorder` installed, first-run permission prompts approved
(system-audio recording + microphone for the terminal running it).
