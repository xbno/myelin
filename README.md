# myelin

Small Mac tools I built for myself: two menu bar apps and the Claude skill that
goes with one of them. Everything here runs locally.

| Where | What |
|-------|------|
| [`recorder/`](recorder/) | **live-recorder** — on-device meeting transcription (menu bar app + CLI). Writes an append-only JSONL transcript as people speak, so anything can read the call *while it is still happening*. `cd recorder && ./install.sh` |
| [`pace/`](pace/) | **Pace** — a menu bar glyph showing whether you are burning your Claude and Codex usage budgets fast enough to hit 100% exactly when each limit resets. `cd pace && ./install.sh` |
| [`skills/live-recorder/`](skills/live-recorder/) | Claude skill that streams the active recording into a Claude session, pulling only the new lines each time. |

Each folder has its own README with the details; `recorder/PRODUCTIZATION.md`
and `pace/DESIGN.md` hold the design decisions.

## Requirements

| | macOS | Chip | Also needs |
|---|---|---|---|
| recorder | 26+ (SpeechAnalyzer) | Apple Silicon | Command Line Tools 26+ (see below) |
| pace | 14+ | any | Command Line Tools 16+ (see below); Claude Code installed and logged in (Pace reads its keychain token, never writes it). The Codex provider is optional and needs the `codex` CLI logged in. |

## Install

```bash
git clone <this repo> ~/ml/myelin
cd ~/ml/myelin/recorder && ./install.sh     # or: cd ~/ml/myelin/pace && ./install.sh
```

Both installers build the app, put it in `/Applications`, and launch it. The
first recording asks for Microphone, System Audio and Calendar access.

### Command Line Tools

Both packages declare `swift-tools-version: 6.0`, so building needs Swift 6 —
Command Line Tools 16 or later. Older tools stop with:

```
error: package 'pace' is using Swift tools version 6.0.0 but the installed version is 5.9.0
```

Check what you have, then install a version matching your macOS:

```bash
swift --version                 # want 6.0 or later
softwareupdate --list           # find "Command Line Tools for Xcode <version>"
sudo softwareupdate --install "Command Line Tools for Xcode 26.6-26.6"
```

recorder also needs the macOS 26 SDK for SpeechAnalyzer, so on macOS 26 install
the 26.x tools rather than an older set. Full Xcode works too, but is not
required for either app.

## Notes

- Recordings are written to `~/ml/myelin/recordings` and are never
  committed. Override with `$LIVE_RECORDER_DIR` or `--out`.
- Both apps are ad-hoc signed, so macOS treats each rebuild as a new app and
  re-asks for permissions. Click Allow again after a rebuild.
- If a menu bar icon does not appear, the bar is probably full: macOS hides the
  leftmost items, and a freshly launched app lands leftmost. ⌘-drag it rightward
  and the position sticks.
