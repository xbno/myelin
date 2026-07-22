#!/bin/bash
# Feasibility spike for the native speaker-naming path.
#
# Run this DURING a live Google Meet call (2+ people who will each talk).
# It reads the meeting app's accessibility tree and figures out whether
# "who is speaking" is exposed there (approach A, pure AX) or whether we
# need the ScreenCaptureKit visual path (approach B).
#
#   ./scripts/ax-spike.sh          # watch mode: diff the tree over ~20s
#   ./scripts/ax-spike.sh dump     # one snapshot of names/buttons
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO_DIR/.build/release/recorder"

[ -x "$BIN" ] || { echo "building recorder…"; ( cd "$REPO_DIR" && swift build -c release ); }

MODE="${1:-watch}"
if [ "$MODE" = "dump" ]; then FLAG="--ax-dump"; else FLAG="--ax-watch"; fi

# Private temp file (the output echoes names scraped from the meeting app).
OUT="$(mktemp -t ax-spike)"
trap 'rm -f "$OUT"' EXIT
if ! "$BIN" "$FLAG" 2>&1 | tee "$OUT" | grep -q "not trusted"; then
  cat "$OUT"
  exit 0
fi

# Not trusted yet: the prompt just opened. Send the user straight there.
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true
cat <<EOF

────────────────────────────────────────────────────────────
Grant Accessibility to:  $BIN
(System Settings ▸ Privacy & Security ▸ Accessibility — it was just added;
flip the switch ON.) Then re-run this script while your Meet call is live.
────────────────────────────────────────────────────────────
EOF
