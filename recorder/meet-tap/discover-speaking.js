// Paste this whole file into the DevTools console of a LIVE Google Meet tab,
// then have people alternate talking for ~20s. Every 2s it prints:
//   • the participant names it can read per tile, and
//   • the CSS class tokens that toggle on tiles as people talk — ranked.
// The top toggling token(s) are Meet's current "is speaking" indicator; paste
// them back and they become SPEAKING_SELECTORS in content.js.
(() => {
  const tiles = () => [...document.querySelectorAll('[data-participant-id]')];
  const STOP = /^(you|presenting|muted|mute|more|pin|is presenting|joined|leave|camera|microphone|mic)\b/i;
  const nameOf = (t) => {
    const c = [...t.querySelectorAll('div,span')]
      .filter((e) => !e.querySelector('div,span'))
      .map((e) => (e.textContent || '').trim())
      .filter((x) => x.length >= 2 && x.length <= 40 && /[a-zA-Z]/.test(x) && !STOP.test(x));
    c.sort((a, b) => (b.includes(' ') - a.includes(' ')) || (a.length - b.length));
    return c[0] || '(no name found)';
  };
  const toggles = {};
  const prev = new Map();
  console.log('[discover] tiles found:', tiles().length, '— names:', tiles().map(nameOf));
  setInterval(() => {
    for (const t of tiles()) {
      const now = new Set();
      t.querySelectorAll('*').forEach((e) => e.classList && e.classList.forEach((c) => now.add(c)));
      const before = prev.get(t) || new Set();
      for (const c of now) if (!before.has(c)) toggles[c] = (toggles[c] || 0) + 1;
      for (const c of before) if (!now.has(c)) toggles[c] = (toggles[c] || 0) + 1;
      prev.set(t, now);
    }
    const ranked = Object.entries(toggles).sort((a, b) => b[1] - a[1]).slice(0, 12);
    console.log('[discover] speaking-class candidates (token → #toggles):', ranked,
      '| names now:', tiles().map(nameOf));
  }, 2000);
})();
