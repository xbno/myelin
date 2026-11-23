#!/bin/sh
# Antigravity invokes this on state changes. Empty startup events carry no quota.
set -eu
umask 077
cache="$HOME/Library/Caches/com.geoff.pace"
mkdir -p "$cache"
tmp=$(mktemp "$cache/antigravity.XXXXXX")
trap 'rm -f "$tmp"' EXIT
/usr/bin/jq -c 'select(.product == "antigravity" and (.quota | type == "object" and length > 0)) |
    {observed: now, plan_tier, quota: (.quota | with_entries(select(.key | startswith("gemini"))))}' > "$tmp"
if [ -s "$tmp" ]; then
    mv -f "$tmp" "$cache/antigravity.json"
fi
