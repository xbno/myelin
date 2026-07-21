# live-recorder

reference recorder-style meeting transcription, **fully on-device**, with live speaker
identification. No bot joins your call, no audio leaves your Mac, no
subscription.

- **Capture**: your microphone + system audio (whatever Zoom/Meet/Teams plays),
  as two separate streams — so your side and their side are attributed for free.
- **ASR**: Apple SpeechAnalyzer (macOS 26+), streaming, on the Neural Engine.
- **Speaker ID**: FluidAudio LS-EEND streaming diarization (CoreML, local)
  labels remote speakers `S1`, `S2`, … in realtime — or **real names** if you
  drop a short voice sample per person into the speakers folder.
- **Output**: an append-only JSONL transcript, written live — built to be
  tailed/streamed by other tools (Claude skill, local analysis tool).

```
{"ts":"2026-07-18T03:06:07Z","source":"system","speaker":"Alice","t0":12.96,"t1":14.28,"text":"This is a sample speaker."}
{"ts":"2026-07-18T03:06:11Z","source":"mic","t0":14.30,"t1":15.85,"text":"Great to meet you both."}
```

## Install (users)

```bash
cd recorder && ./install.sh
```

That builds `LiveRecorder.app`, installs it to `/Applications`, and launches
it. Requires macOS 26+ and Xcode Command Line Tools. Look for the waveform
icon in your menu bar:

| Off (idle) | On (recording) |
|------------|----------------|
| ![menu bar, idle](docs/menu-bar-off.png) | ![menu bar, recording](docs/menu-bar-on.png) |

Gray waveform = idle. Red, bouncing waveform = recording.

**Shortcuts** (global — they work from any app):

- **⌥⌘R** — start / stop recording. Recordings are named after your current
  calendar event (it asks for a name when there isn't one).
- **⌥⌘C** — ask Claude about the live call: opens Claude Cowork with the
  transcript folder attached and `/live-recorder` ready to go.

The menu has the rest: open the live transcript in a browser, open the
transcripts folder, echo cancellation (on by default — lets you skip
headphones), Launch at Login, quit.

Your **first recording** downloads the speech + diarization models (one time,
~a minute) and triggers one-time permission prompts — Microphone, System
Audio Recording, and Calendar (used only to name transcripts). Click Allow.

Optional add-ons:

- **Real speaker names on Meet/Teams/Zoom calls**: load the `meet-tap/` Chrome
  extension — see [meet-tap/README.md](meet-tap/README.md).
- **Claude skill**: `make skill-zip` writes `~/Downloads/live-recorder-skill.zip`;
  upload it at claude.ai → Settings → Capabilities → Skills. It lets any
  Claude session stream the live call's transcript incrementally.

## Building the app yourself

`install.sh` is just requirement checks + `make app-install`. For development:

```bash
cd recorder && make app        # builds LiveRecorder.app (recorder bundled inside)
open LiveRecorder.app          # waveform appears in the menu bar
make app-install               # or: copy to /Applications and launch
```

The app is menu-bar-only (no dock icon); it supervises the `recorder` binary
and names each transcript from your calendar.

### Running it "hacky" before we have an Apple Developer account

Signing/notarization is only needed to *distribute* the app. For yourself:

- **`make app` builds it locally**, so it has no quarantine flag → it opens
  without any Gatekeeper right-click dance. The `make app` step ad-hoc-signs it
  so macOS can attach your TCC (mic/audio/calendar) grants.
- **Launch at login**: System Settings → General → Login Items → **+** →
  `/Applications/LiveRecorder.app`.
- **Caveat**: an ad-hoc-signed app can be re-prompted for permissions after a
  rebuild (the signature changes). Annoying but harmless — just re-grant.

**Sharing to a user without a dev account** (manual): zip the
`.app`, they unzip and run `xattr -dr com.apple.quarantine LiveRecorder.app`
(strips the download quarantine so the unsigned app opens), then double-click.
Proper fix later: sign + notarize with an Apple Developer account and
ship a DMG — then it's just drag-to-Applications.

## CLI use (terminals, scripts, hacking)

The menu-bar app is the everyday way to record. There's also a plain CLI —
`make install` puts `recorder` on your PATH (`~/.local/bin`):

```bash
recorder                      # record + transcribe until Ctrl-C
recorder --help               # --out, --locale, --mic-only, --system-only,
                              # --no-diarize, --aec, --speakers-dir, --diarize-file
```

Transcripts land in `~/ml/myelin/recordings/` (one `.jsonl` per call).
This lives inside the project folder so sandboxed agents (e.g. Claude Cowork,
scoped to the repo) can read it — `~/Library/…` is a macOS-protected path they
can't mount. Override with `$LIVE_RECORDER_DIR` or `--out`. The folder is
gitignored (call transcripts are never committed).

**Named speakers**, two ways (both feed the same voice model):

- **Voice samples**: put 5–10s clips in
  `~/ml/myelin/recordings/speakers/` — `Alice.wav` makes
  that voice show up as `Alice`. Mic lines are always you.
- **Meeting-app integration** (`meet-tap/`, optional): a tiny Chrome extension
  reads the **active speaker** from the meeting page's DOM (captions as
  fallback) on Google Meet, Teams (web), and Zoom (web client) and streams
  the name to the recorder on localhost — the same method reference recorder's
  Companion extension uses. Names apply live, the diarizer adopts them for
  that voice, and at session end each newly named voice is saved to
  `speakers/<Name>.wav` — so people stay identified with the extension off,
  during screen share, and on every future call on any platform (including
  desktop apps). See `meet-tap/README.md`.

**Live view in the terminal**: in-progress hypotheses repaint a status line;
finalized lines print as `me> …` / `them> …` / `Alex> …`.

**Claude integration**: the `live-recorder` skill lets Claude poll the active
call incrementally (only new lines each pull) to take notes / research live.
`make skill-zip` packages it to `~/Downloads` for upload at claude.ai →
Settings → Capabilities → Skills. See `../skills/live-recorder/SKILL.md`.

## Compare against reference recorder

Run both during the same call (they don't conflict — taps are independent),
then:

```bash
scripts/compare.py --diy <transcript.jsonl> --reference-recorder-doc <reference-recorder-doc-id>
```

prints stats + an interleaved timeline of both transcripts on one clock.

## Test process (from zero to a verdict)

**Smoke test (2 min, no meeting):** headphones on → `recorder` in a terminal →
play any YouTube interview + talk out loud → watch `me>` / `S1>` / `S2>` lines
appear live → Ctrl-C. Transcript path is printed at the end.

**Real call (the actual verdict):**

1. (Once, optional but recommended) drop 5–10s voice clips of your regulars
   into `~/ml/myelin/recordings/speakers/` —
   `Alice.wav` → named lines. Old archived/reference recorder recordings are a fine source.
2. Before the call: `recorder` in a terminal. Start reference recorder too — they
   coexist fine. Wear headphones.
3. During: in a Claude session, say "pull the live call" — repeat pulls
   return only new lines (live notes / research loop).
4. After: Ctrl-C, then compare head-to-head:
   `scripts/compare.py --diy <transcript.jsonl> --reference-recorder-doc <id>`
   (get the reference recorder doc id from the reference recorder app or `reference-recorder_export.py`.)

**What to judge:** word accuracy on jargon, speaker-split correctness (were
two remote speakers separated?), latency of lines appearing, and whether Me/Them ever
cross-bleed (if they do — headphones).


## Judging quality / gotchas

- **No headphones? Turn on echo cancellation.** Without AEC the mic hears the
  speakers and remote speech bleeds into your "me" channel. The menu-bar app
  has it on by default; the CLI needs `--aec`. With headphones you don't need
  either.
- Diarization needs a few seconds of a new voice before it splits reliably;
  very short interjections may get the neighbor's label.
- Synthetic voices (`say`, TTS demos) don't diarize — EEND models key on real
  human voice characteristics.
- `--diarize-file x.wav` runs offline diarization on a file — useful for
  debugging and for checking a voice sample before enrolling it.

## Architecture (for hacking)

```
Sources/Recorder/
  SystemAudioTap.swift   Core Audio process tap (macOS 14.2+ API) → aggregate
                         device → IOProc. Captures ALL system output.
  MicCapture.swift       AVAudioEngine input tap.
  SpeechChannel.swift    One streaming SpeechAnalyzer session per source;
                         converts arbitrary input formats; volatile results →
                         console, finals → writer (with speaker label).
  Diarization.swift      FluidAudio LS-EEND streaming diarizer on the system
                         channel + enrollment; SegmentStore answers
                         "who spoke during [t0,t1]?" at write time.
  TranscriptWriter.swift Serialized JSONL appends (actor).
  Main.swift             CLI, wiring, graceful shutdown (SIGINT/SIGTERM).
```

Design notes: the two capture channels are never mixed (channel = Me/Them
attribution, and diarization only runs on the remote channel); every stage is
streaming (hard requirement — downstream tools consume the JSONL live); ASR
and diarization share the stream clock, so utterances are labeled by dominant
overlap.

## Roadmap

- Signed/notarized distribution (Apple Developer account → DMG) and
  a Chrome Web Store (unlisted) listing for meet-tap
- Native Accessibility adapter for the Zoom/Teams **desktop** apps (they
  expose active speaker to AX — spike tooling in `scripts/ax-spike.sh`)
- Parakeet-v3 ASR option (FluidAudio) for messy multi-accent calls
- Calendar-attendee hints (map unknown voices to the meeting's invite list)

Shipped: AEC (`--aec`, app default), menu-bar app, cross-call speaker memory
(voices named once are saved to `speakers/` and auto-recognized), meet-tap
active-speaker naming, local analysis tool live feed, Claude live-pull skill.
