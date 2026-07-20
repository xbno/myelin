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

Requires macOS 26+ and Xcode Command Line Tools. First run downloads the
speech + diarization models and triggers two one-time permission prompts
(System Audio Recording, Microphone) for your terminal app.

## Menu-bar app (LiveRecorder.app)

A no-terminal way to use it: a menu-bar app that names each meeting from your
calendar and supervises the `recorder` binary for you.

```bash
cd recorder && make app        # builds LiveRecorder.app (recorder bundled inside)
open LiveRecorder.app          # 🎙 appears in the menu bar
# or install it:
make app-install               # copies to /Applications
```

Menu: **Start recording** (names the transcript from your current calendar
event), **Stop**, **Open live transcript** (→ http://127.0.0.1:8737), **Open
transcripts folder**, **Quit**. It's menu-bar-only (no dock icon). First record
prompts for Microphone + System Audio (the recorder) and Calendar (naming).

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

## Use

```bash
recorder                      # record + transcribe until Ctrl-C
recorder --help               # --out, --locale, --mic-only, --system-only,
                              # --no-diarize, --speakers-dir, --diarize-file
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
- **Google Meet integration** (`meet-tap/`, optional): a tiny Chrome extension
  reads Meet's caption speaker names and streams them to the recorder on
  localhost. Names apply live AND the diarizer adopts them for that voice —
  so people stay identified after captions stop, during screen share, and on
  future non-Meet calls. See `meet-tap/README.md`.

**Live view in the terminal**: in-progress hypotheses repaint a status line;
finalized lines print as `me> …` / `them> …` / `Alex> …`.

**Claude integration**: `make skill` installs the `live-recorder` skill; Claude
can then poll the active call incrementally (only new lines each pull) to take
notes / research live. See `../skills/live-recorder/SKILL.md`.

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

- **Wear headphones.** Without them the mic hears the speakers and remote
  speech bleeds into your "me" channel (echo cancellation is on the roadmap).
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

- Acoustic echo cancellation (no-headphones mode)
- Persistent cross-call speaker memory (auto-recognize once named)
- Menu-bar app wrapper + signed/notarized distribution
- Parakeet-v3 ASR option (FluidAudio) for messy multi-accent calls
- local analysis tool live feed (`QueueSource` ← transcript JSONL)
