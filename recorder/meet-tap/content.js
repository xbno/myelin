// meet-tap: report the meeting platform's ACTIVE SPEAKER to the local
// live-recorder — the same method reference recorder's "Companion" extension uses.
//
// Primary signal: the platform's own active-speaker indicator in the DOM
// (the tile that's currently talking). No captions required. Captions are a
// fallback when the active-speaker signal isn't found. We POST
// {"names":["Alice"]} to the recorder's localhost ingest whenever the current
// speaker changes, [] on silence.
//
// Meet obfuscates and reshuffles its class names, so the active-speaker
// detector uses a list of known signals AND a self-describing discovery mode:
// set DEBUG = true, open DevTools on the meeting tab, and it prints which CSS
// classes toggle as people talk — paste those to re-lock SPEAKING_SELECTORS.

const ENDPOINT = 'http://127.0.0.1:8737/speaking';
const DIAG_ENDPOINT = 'http://127.0.0.1:8737/diag';
const DEBUG = true; // dev: stream what this script sees to the recorder's /diag
const POLL_MS = 400;
const STALE_MS = 1500; // active-speaker highlight is prompt; caption path lingers

let lastSent = '';

function send(names) {
  const key = names.join('|');
  if (key === lastSent) return;
  lastSent = key;
  if (DEBUG) console.log('[meet-tap] send', names);
  fetch(ENDPOINT, { method: 'POST', body: JSON.stringify({ names }), keepalive: true })
    .catch(() => {});
}

// Names that are UI chrome, not people — never report these.
const STOPWORDS = /^(you|presenting|muted|unmute|mute|more|pin|screen|is presenting|joined|leave|camera|microphone|mic)\b/i;

function looksLikeName(t) {
  return t && t.length >= 2 && t.length <= 40 && !STOPWORDS.test(t) &&
    /[a-zA-Z]/.test(t) && !/[:{}<>]/.test(t);
}

// ===========================================================================
// Google Meet — active speaker (primary)
// ===========================================================================

// Tiles have carried data-participant-id for years — the stable anchor.
function meetTiles() {
  return [...document.querySelectorAll('[data-participant-id]')];
}

// Best-effort display name for a tile: the shortest name-like leaf text.
function meetTileName(tile) {
  if (tile.hasAttribute('data-self-name')) return tile.getAttribute('data-self-name');
  const cands = [...tile.querySelectorAll('div,span')]
    .filter((e) => !e.querySelector('div,span'))
    .map((e) => (e.textContent || '').trim())
    .filter(looksLikeName);
  // Prefer a full "First Last" name (has a space) over short UI labels; among
  // equals, the shortest. This avoids grabbing an icon/status leaf.
  cands.sort((a, b) => (b.includes(' ') - a.includes(' ')) || (a.length - b.length));
  return cands[0] || null;
}

// Known "this tile is speaking" signals, most-recent first. Verified/updated
// via DEBUG discovery below. A tile counts as speaking if it MATCHES or CONTAINS
// any of these.
const SPEAKING_SELECTORS = [
  '.IisKdb',            // historical animated sound-bars element
  '[data-is-speaking="true"]',
  '.rrf9lc',            // historical speaking-ring
  '[class*="speaking"]',
];

function meetTileSpeaking(tile) {
  return SPEAKING_SELECTORS.some((sel) => {
    try {
      return tile.matches(sel) || tile.querySelector(sel) !== null;
    } catch { return false; }
  });
}

function readMeetActiveSpeaker() {
  const speaking = meetTiles().filter(meetTileSpeaking).map(meetTileName).filter(Boolean);
  return speaking.length ? { names: speaking } : null;
}

// DEBUG: discover the speaking-indicator class by watching which class tokens
// toggle on tiles over time. Whatever toggles as people alternate talking is
// the signal — add it to SPEAKING_SELECTORS. Module scope so /diag telemetry
// can report the live ranking.
const classToggles = {}; // classToken -> times it appeared/disappeared
function startMeetDiscovery() {
  const prev = new Map(); // tile -> Set(classTokens)
  setInterval(() => {
    for (const tile of meetTiles()) {
      const now = new Set();
      tile.querySelectorAll('*').forEach((e) =>
        e.classList && e.classList.forEach((c) => now.add(c)));
      const before = prev.get(tile) || new Set();
      for (const c of now) if (!before.has(c)) classToggles[c] = (classToggles[c] || 0) + 1;
      for (const c of before) if (!now.has(c)) classToggles[c] = (classToggles[c] || 0) + 1;
      prev.set(tile, now);
    }
    const ranked = Object.entries(classToggles).sort((a, b) => b[1] - a[1]).slice(0, 12);
    console.log('[meet-tap] class tokens toggling on tiles (candidates for speaking):', ranked);
  }, 2000);
}

// ===========================================================================
// Caption fallbacks (used only if no active-speaker signal is available)
// ===========================================================================

function leafNameText(node) {
  const texts = [...node.querySelectorAll('div,span')]
    .filter((e) => !e.querySelector('div,span'))
    .map((e) => (e.textContent || '').trim())
    .filter(Boolean);
  if (texts.length >= 2) {
    const name = texts.find((t) => looksLikeName(t));
    const text = texts.reduce((a, b) => (b.length > a.length ? b : a), '');
    if (name && text && name !== text) return { names: [name] };
  }
  return null;
}

function readMeetCaption() {
  const region = document.querySelector('[aria-label="Captions"]') ||
    document.querySelector('[aria-label*="aption"]') ||
    document.querySelector('.a4cQT');
  if (!region) return null;
  const avatars = region.querySelectorAll('img');
  if (!avatars.length) return null;
  let node = avatars[avatars.length - 1].parentElement;
  for (let d = 0; node && node !== region && d < 5; d++, node = node.parentElement) {
    const cap = leafNameText(node);
    if (cap) return cap;
  }
  return null;
}

function readTeamsCaption() {
  const region = document.querySelector('[data-tid="closed-captions-renderer"]');
  if (!region) return null;
  const blocks = region.querySelectorAll('.fui-ChatMessageCompact');
  const last = blocks.length ? blocks[blocks.length - 1] : region;
  const name = last.querySelector('[data-tid="author"]')?.textContent?.trim();
  if (name && looksLikeName(name)) return { names: [name] };
  return leafNameText(last);
}

function readZoomCaption() {
  const overlay = document.querySelector('[class*="live-transcription-subtitle"]');
  if (overlay) {
    const m = (overlay.textContent || '').trim().match(/^([^:]{1,40}):\s*(.+)$/s);
    if (m && looksLikeName(m[1].trim())) return { names: [m[1].trim()] };
  }
  const items = document.querySelectorAll('[class*="lt-message"]');
  if (items.length) return leafNameText(items[items.length - 1]);
  return null;
}

// ===========================================================================
// Per-platform adapter: activeSpeaker (primary) + caption (fallback)
// ===========================================================================

function pickAdapter() {
  const h = location.hostname;
  if (h === 'meet.google.com')
    return { active: readMeetActiveSpeaker, caption: readMeetCaption, discover: startMeetDiscovery };
  if (h.endsWith('teams.microsoft.com') || h.endsWith('teams.live.com'))
    return { active: () => null, caption: readTeamsCaption };
  if (h === 'zoom.us' || h.endsWith('.zoom.us'))
    return { active: () => null, caption: readZoomCaption };
  return null;
}

const adapter = pickAdapter();
let lastCaption = { names: [], at: 0 };

function tick() {
  const now = Date.now();
  // 1) active-speaker (no captions needed)
  const act = adapter.active();
  if (act && act.names.length) { send(act.names); return; }
  // 2) caption fallback (linger briefly so it doesn't flicker to silence)
  const cap = adapter.caption();
  if (cap && cap.names.length) { lastCaption = { names: cap.names, at: now }; }
  if (now - lastCaption.at < STALE_MS) { send(lastCaption.names); return; }
  send([]); // silence
}

// DEBUG telemetry: every 3s, POST what this script currently sees to the
// recorder — readable with `curl 127.0.0.1:8737/diag` — so the extension side
// can be debugged end-to-end without opening DevTools.
function collectDiag() {
  const tiles = meetTiles();
  return {
    ts: new Date().toISOString(),
    url: location.pathname,
    tiles: tiles.length,
    tileNames: tiles.map(meetTileName),
    speakingNow: tiles.filter(meetTileSpeaking).map(meetTileName),
    // Per-selector match counts across tiles — a selector matching ALL tiles
    // constantly is a stale/over-broad signal, not the speaking indicator.
    selectorHits: SPEAKING_SELECTORS.map((sel) => {
      let n = 0;
      for (const t of tiles) {
        try { if (t.matches(sel) || t.querySelector(sel)) n++; } catch {}
      }
      return [sel, n];
    }),
    captionRegionFound: !!(document.querySelector('[aria-label="Captions"]') ||
      document.querySelector('[aria-label*="aption"]') || document.querySelector('.a4cQT')),
    topClassToggles: Object.entries(classToggles).sort((a, b) => b[1] - a[1]).slice(0, 12),
    lastSent,
  };
}

if (adapter) {
  setInterval(tick, POLL_MS);
  if (DEBUG && adapter.discover) adapter.discover();
  if (DEBUG) {
    setInterval(() => {
      fetch(DIAG_ENDPOINT, { method: 'POST', body: JSON.stringify(collectDiag()), keepalive: true })
        .catch(() => {});
    }, 3000);
    console.log('[meet-tap] active on', location.href);
  }
}
