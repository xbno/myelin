# live-recorder

Meeting transcription, **fully on-device**, built so the transcript can be
**streamed mid-call** to other tools.

**Why:** an append-only JSONL transcript lets local tools work with a call while
it is still happening. The Claude skill pulls only the new lines each time, and
on-device processing means no bot joins the call and no audio leaves your Mac.

**How:** mic + system audio as separate streams (your side vs theirs for
free), live ASR (Apple SpeechAnalyzer, macOS 26+), live speaker labeling.

## Install the app

```bash
cd recorder && make app-install
```

Builds `LiveRecorder.app`, installs it to `/Applications`, and launches it.
Requires macOS 26+ and Xcode Command Line Tools. Your first recording
downloads the models (one time, ~a minute) and asks for permissions —
Microphone, System Audio Recording, and Calendar (only used to name
transcripts after your current meeting). Click Allow.

| Off (idle) | On (recording) |
|------------|----------------|
| ![menu bar, idle](docs/menu-bar-off.png) | ![menu bar, recording](docs/menu-bar-on.png) |

**Shortcuts** (global — they work from any app):

- **⌥⌘R** — start / stop recording. Named after your current calendar event.
- **⌥⌘C** — ask Claude about the live call: opens Claude Cowork with the
  transcript attached and `/live-recorder` ready to go.

### Cowork must run tasks locally

Cowork tasks can run in two places — on your Mac or in a cloud VM — and the
app's default can flip to cloud after an update. **The live-recorder skill
requires local**: a cloud VM only gets a staged snapshot of any connected
folder, so the growing transcript never updates and every pull flatlines at
"no new segments". Local sessions read the real file directly — no
connecting folders, no re-staging per pull — and save the session trace to
disk (`~/Library/Application Support/Claude/…`); cloud traces stay
server-side.

- **Permanently:** desktop app → Settings → Cowork → turn **off** "Run new
  tasks in the cloud".
- **Per task:** the "Run this task" picker (top right) when starting a task.
- A session's location is fixed at start — an already-running cloud session
  can't be moved, but the next ⌥⌘C can be local.

Cloud mode's honest use case is kick-off-and-walk-away work (keeps running
with the laptop closed, reachable from your phone, hosts scheduled tasks) —
never live-call support.

## CLI

For terminals and scripts — `make install` puts `recorder` on your PATH:

```bash
recorder                      # record + transcribe until Ctrl-C
recorder --help               # --out, --locale, --mic-only, --system-only,
                              # --no-diarize, --aec, --diarize-file
```

Transcripts land in the folder picked in the menu bar (`Recordings folder…`),
saved as one line in `~/.config/live-recorder/recordings-dir` — the app, this
CLI and the Claude skill all read it, so no checkout path is hardcoded. One
`.jsonl` per call, gitignored — never committed. The folder is created if it
doesn't exist. Override one run with `$LIVE_RECORDER_DIR` or `--out`.

## Claude skill

```bash
make skill-zip                # writes ~/Downloads/live-recorder-skill.zip
```

Upload the zip at claude.ai → Settings → Capabilities → Skills. Then
`/live-recorder` in any Claude session streams the active call incrementally
(each pull returns only new lines) for live notes / research.

## Gotchas

- **No headphones? Keep echo cancellation on** (app default; CLI needs
  `--aec`), or the mic hears your speakers and remote speech bleeds into
  your "me" channel.
- Diarization is a WIP: it needs a few seconds of a new voice before it
  splits reliably, and very short interjections may get the neighbor's label.
