// meet-tap: report Google Meet's active speaker to the local live-recorder.
//
// Primary signal: Meet's caption blocks (turn captions ON — the CC button).
// Each caption block carries the speaker's display name; we report the name
// on the most recent block. POSTs {"names":["Alice"]} to the recorder's
// localhost hint listener whenever the speaker changes, [] on silence.
//
// Google ships DOM changes regularly; selectors here are heuristics with
// fallbacks. If names stop flowing, set DEBUG = true and check the console —
// it prints what it sees so fixing is usually a one-liner.

const ENDPOINT = 'http://127.0.0.1:8737/speaking';
const DEBUG = false;
const POLL_MS = 500;
const STALE_MS = 4000; // captions linger after speech; drop stale names

let lastSent = '';
let lastChange = 0;
let lastSeen = { name: '', text: '' };

function send(names) {
  const key = names.join('|');
  if (key === lastSent) return;
  lastSent = key;
  if (DEBUG) console.log('[meet-tap] send', names);
  fetch(ENDPOINT, {
    method: 'POST',
    body: JSON.stringify({ names }),
    keepalive: true,
  }).catch(() => {});
}

function captionRegion() {
  return (
    document.querySelector('[aria-label="Captions"]') ||
    document.querySelector('[aria-label*="aption"]') ||
    document.querySelector('[jsname="dsyhDe"]') || // historical caption scroller
    document.querySelector('.a4cQT') // historical caption container
  );
}

// The newest caption block: name node sits near an avatar <img>; the caption
// text is the longer text that follows. We take the short text nearest the
// last avatar as the speaker name.
function readLatestCaption() {
  const region = captionRegion();
  if (!region) return null;
  const avatars = region.querySelectorAll('img');
  if (!avatars.length) return null;
  const last = avatars[avatars.length - 1];

  let node = last.parentElement;
  for (let depth = 0; node && node !== region && depth < 5; depth++, node = node.parentElement) {
    const texts = [...node.querySelectorAll('div,span')]
      .filter((e) => !e.querySelector('div,span')) // leaf nodes only
      .map((e) => (e.textContent || '').trim())
      .filter(Boolean);
    if (texts.length >= 2) {
      // name = first short leaf; text = longest leaf
      const name = texts.find((t) => t.length > 0 && t.length <= 40);
      const text = texts.reduce((a, b) => (b.length > a.length ? b : a), '');
      if (name && text && name !== text) return { name, text };
    }
  }
  return null;
}

function tick() {
  const cap = readLatestCaption();
  const now = Date.now();
  if (cap) {
    if (cap.name !== lastSeen.name || cap.text !== lastSeen.text) {
      lastSeen = cap; // caption is still growing → someone is talking
      lastChange = now;
    }
    if (DEBUG) console.log('[meet-tap] caption', cap);
    if (now - lastChange < STALE_MS) {
      send([cap.name]);
      return;
    }
  }
  send([]); // silence / no captions visible
}

setInterval(tick, POLL_MS);
if (DEBUG) console.log('[meet-tap] active on', location.href);
