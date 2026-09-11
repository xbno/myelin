#!/usr/bin/env bash
# One-shot installer. From a checkout:  cd pace && ./install.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "== Pace installer =="

os_major=$(sw_vers -productVersion | cut -d. -f1)
if [ "$os_major" -lt 14 ]; then
    echo "ERROR: macOS 14+ required. You have $(sw_vers -productVersion)." >&2
    exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
    echo "Xcode Command Line Tools missing — launching installer (rerun me after)."
    xcode-select --install
    exit 1
fi
if ! security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
    echo "NOTE: no Claude Code login found in the keychain."
    echo "      Install Claude Code and run 'claude' once; Pace picks the token up from there."
fi

make app-install

echo
echo "== done =="
echo "Pace is in your menu bar: the orange mark and three bars."
echo "Click it for the popover, the gear for settings. Launch at Login is in settings."
