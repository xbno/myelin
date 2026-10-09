#!/usr/bin/env bash
# One-shot installer. From a repo checkout:
#   cd recorder && ./install.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "== live-recorder installer =="

# 1. Requirements
os_major=$(sw_vers -productVersion | cut -d. -f1)
if [ "$os_major" -lt 26 ]; then
    echo "ERROR: macOS 26+ required (SpeechAnalyzer). You have $(sw_vers -productVersion)." >&2
    exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
    echo "Xcode Command Line Tools missing — launching installer (rerun me after)."
    xcode-select --install
    exit 1
fi

# 2. Build + install + launch the menu-bar app
make app-install

echo
echo "== done =="
echo "LiveRecorder is running — look for the waveform icon in your menu bar"
echo "(gray = idle; red and bouncing = recording)."
echo
echo "Shortcuts (global, from any app):"
echo "  ⌥⌘R   start / stop recording"
echo "  ⌥⌘C   ask Claude about the live call (opens Cowork with the transcript)"
echo
echo "First recording:"
echo "  - downloads the speech + diarization models (one time, ~a minute)"
echo "  - macOS asks for Microphone + System Audio Recording (and Calendar,"
echo "    used to name transcripts after your current meeting) — click Allow."
echo
echo "Transcripts: menu-bar icon → Open transcripts folder."
