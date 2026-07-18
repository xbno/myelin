#!/usr/bin/env bash
# One-shot installer for users. From a repo checkout:
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

# 2. Build + install binary and Claude skill
make install
make skill

echo
echo "== done =="
echo "Run:  recorder            (Ctrl-C to stop; transcript path is printed)"
echo
echo "First run:"
echo "  - downloads the speech + diarization models (one time, ~a minute)"
echo "  - macOS will ask for System Audio Recording and Microphone permission"
echo "    for your terminal app — click Allow, then rerun."
echo
echo "Named speakers: drop short voice samples (Alice.wav, Bob.m4a, 5-10s of"
echo "them talking) into:"
echo "  ~/Library/Application Support/live-recorder/speakers/"
echo "Their lines will be labeled with their names instead of S1/S2."
