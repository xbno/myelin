# meet-tap

Chrome extension that reports the meeting's **active speaker** to the local
live-recorder — the same method reference recorder's "Companion" extension uses. It reads
who's currently talking straight from the meeting page's DOM (no captions
required) and streams the name to the recorder, which shows real names instead
of `S1`/`S2` for the rest of that call. Nothing is kept afterwards: the recorder
stores no voice data, so the next call starts anonymous again.

Everything stays on your machine: the extension only talks to
`http://127.0.0.1:8737`.

Primary signal is the **active-speaker indicator**; **captions** are a fallback
when that isn't available. Works on Google Meet (reference), with Teams and Zoom
web adapters in the same file.

## Install

1. Chrome → `chrome://extensions` → enable **Developer mode**
2. **Load unpacked** → select this `meet-tap/` folder
3. Start `recorder`; join your call in Chrome. That's it — no captions needed.

## Locking the active-speaker selector (one-time per platform)

Meet obfuscates and reshuffles its CSS class names, so the "is speaking" class
in `SPEAKING_SELECTORS` (in `content.js`) needs to be confirmed/updated
occasionally. To find the current one:

1. Join a live Meet call with someone.
2. Open DevTools on the Meet tab → Console.
3. Paste the entire contents of `discover-speaking.js` and press Enter.
4. Have people alternate talking ~20s. The console ranks the CSS class tokens
   that toggle as speakers change — the top one is the speaking indicator.
5. Put it at the top of `SPEAKING_SELECTORS` in `content.js`, reload the
   extension.

(Same maintenance path reference recorder and other tools use — the DOM is the only place
this signal exists; it is deliberately not in the accessibility tree.)

## When it breaks

If names stop flowing, set `DEBUG = true` at the top of `content.js`, reload the
extension, and check the Meet tab's console — it runs the same discovery and
prints what it sees. Re-lock the selector as above. Diarization keeps working regardless; you
only lose real names and fall back to `S1`/`S2`.

To check whether names are flowing without turning `DEBUG` on, run
`curl 127.0.0.1:8737/hints` during a call — it lists the last 50 speaker
intervals the recorder received.
