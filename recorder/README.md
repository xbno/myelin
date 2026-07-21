# live-recorder

reference recorder-style meeting transcription, **fully on-device**: captures your mic +
system audio, transcribes live (Apple SpeechAnalyzer, macOS 26+), labels who's
speaking, and writes a JSONL transcript other tools can tail while the call is
still going (Claude skill, local analysis tool).

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

## CLI

For terminals and scripts — `make install` puts `recorder` on your PATH:

```bash
recorder                      # record + transcribe until Ctrl-C
recorder --help               # --out, --locale, --mic-only, --system-only,
                              # --no-diarize, --aec, --speakers-dir, --diarize-file
```

Transcripts land in `~/ml/myelin/recordings/` (one `.jsonl` per call,
gitignored — never committed). Override with `$LIVE_RECORDER_DIR` or `--out`.

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
