#!/usr/bin/env bash
# One-shot installer for the menu bar. From a checkout:  cd tasks && ./install.sh
# Run it after the bridge or direct-API setup in README.md. It:
#   1. creates the Python env (uv sync)
#   2. links the plugin into SwiftBar's plugin folder
#   3. installs a launchd agent that starts SwiftBar at login and restarts it if it crashes
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
here=$(pwd)
label=com.myelin.swiftbar
agent="$HOME/Library/LaunchAgents/$label.plist"

echo "== tasks installer =="

if ! command -v uv >/dev/null; then
    echo "ERROR: uv not found. Install it from https://docs.astral.sh/uv/ and run me again." >&2
    exit 1
fi
if [ ! -d /Applications/SwiftBar.app ]; then
    echo "ERROR: SwiftBar not found. Install it (brew install --cask swiftbar) and run me again." >&2
    exit 1
fi

uv sync --quiet

# Stop any SwiftBar first, so the agent below is the only one running it.
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
pkill -x SwiftBar 2>/dev/null || true
sleep 1

plugins=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || echo "$HOME/.swiftbar")
mkdir -p "$plugins"
defaults write com.ameba.SwiftBar PluginDirectory "$plugins"
ln -sf "$here/swiftbar/gtasks.5m.py" "$plugins/gtasks.5m.py"
echo "plugin linked into $plugins"

mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__HOME__|$HOME|g" "swiftbar/$label.plist" > "$agent"
launchctl bootstrap "gui/$(id -u)" "$agent"
echo "SwiftBar started; it now starts at login and restarts if it crashes."
echo
echo "== done =="
echo "Look for the checklist icon in your menu bar. ⌘⌥T opens it."
