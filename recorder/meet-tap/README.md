# meet-tap

Chrome extension that reports Google Meet's **active speaker name** to the
local live-recorder — the same platform-integration trick reference recorder uses, but
here it also **teaches the voice model**: the first time Meet attributes an
utterance to "Alice", the recorder names that voice slot, so Alice stays
identified by voice alone afterwards (screen share, captions off, next call
on Zoom or a phone bridge).

Everything stays on your machine: the extension only talks to
`http://127.0.0.1:8737`.

## Install

1. Chrome → `chrome://extensions` → enable **Developer mode**
2. **Load unpacked** → select this `meet-tap/` folder

## Use

1. Start `recorder` (it prints `meet-tap hint listener on …:8737`)
2. Join your Meet call and **turn captions ON** (the CC button) — speaker
   names ride on the caption blocks
3. That's it — transcript lines show real names instead of S1/S2, and you'll
   see `voice S2 identified as "Alice" (meet-tap)` in the recorder output

## When it breaks

Google reshuffles Meet's DOM a few times a year. If names stop flowing:
set `DEBUG = true` at the top of `content.js`, reload the extension, open
DevTools on the Meet tab, and look at what `[meet-tap] caption` prints —
adjusting one selector in `captionRegion()`/`readLatestCaption()` is usually
the whole fix. The voice pipeline keeps working regardless; you only lose the
automatic naming until fixed (enrolled voices are unaffected).
