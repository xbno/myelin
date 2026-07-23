---
name: live-recorder
description: Pull live transcripts incrementally into context if recording live
user-invocable: true
disable-model-invocation: true
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
**step 1, before any pull** (skip only if the session already has it). Request access
to `~/ml/myelin` with the folder-access tool; its response prints the
connected path. From then on always pull with the recordings path pinned:

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
- Output: header `<file> — segments 5–12 of 12`, then `**Me:** …` /
  `**S1:** …` blocks (mic is always Me; system audio is diarized into
  S1/S2/… or "Them"). Consecutive segments from the same speaker are
  collapsed into one block; a ≥3s silence gap starts a new block. Speaker
  labels are approximate — one label can span multiple real people, so
  treat block boundaries as hints, not ground truth.
- `no new segments (still N)` → nothing new; wait (e.g. `sleep 30`) and pull
  again. Polling every 20–60s during a call is plenty.
- `(output capped — N more segments; run again to continue)` → big backlog is
  delivered in bounded chunks (so the harness never offloads the output to an
  unreadable overflow file); just run the same command again until caught up.
- `transcript shrank … starting over` → file was replaced; re-streams from
  the top.

Flags: `--list` (recent transcripts), `--file <path>` (pin one),
`--reset` (zero cursor), `--dir`, `--state-dir`.

**Full transcript / re-read:** when the user says "full transcript", "reread",
"pull the whole thing", "start over", or "catch me up from the top", run
`scripts/pull.py --full`. It prints the entire transcript from segment 1
(ignoring the cursor), then advances the cursor to the end so plain "pull"
resumes incrementally afterward.

## Invoked with a specific transcript (not live)

If the invocation argument is a path (absolute, or a filename that matches a
file in the recordings dir) rather than free text, that path is the target
transcript — e.g. `/live-recorder /Users/…/recordings/acme-2026-07-23T16-10-33Z.jsonl`.
This is almost always a **finished** call, not the live one, so treat it as a
one-shot reference read, not a polling loop:

```bash
python3 <skill-dir>/scripts/pull.py --file <path> --full
```

`--full` ignores any stale cursor from earlier in this session and guarantees
the whole transcript. Pull it once, use it as reference material, and don't
re-pull before every answer — the file isn't growing, so there's nothing new
to catch. The "Workflow" section below (pull-before-every-answer, rolling
summary) applies only to the live/no-argument case.

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
