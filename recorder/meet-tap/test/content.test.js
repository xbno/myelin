// Runs content.js against a tiny fake Meet DOM (no browser needed):
//   node --test meet-tap/test/*.test.js
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// --- minimal DOM: only what content.js's Meet adapter queries --------------
class El {
  constructor(tag, attrs = {}, children = [], text = '') {
    this.tagName = tag; this.attrs = attrs; this.children = children; this.text = text;
    this.classList = {
      forEach: (f) => (attrs.class || '').split(/\s+/).filter(Boolean).forEach(f),
    };
  }
  get textContent() { return this.text + this.children.map((c) => c.textContent).join(''); }
  hasAttribute(n) { return n in this.attrs; }
  getAttribute(n) { return this.attrs[n] ?? null; }
  descendants() { return this.children.flatMap((c) => [c, ...c.descendants()]); }
  matches(sel) { return sel.split(',').some((s) => matchOne(this, s.trim())); }
  querySelectorAll(sel) { return this.descendants().filter((e) => e.matches(sel)); }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
}
function matchOne(el, s) {
  if (s === '*') return true;
  let m;
  if ((m = s.match(/^\.([\w-]+)$/))) return (el.attrs.class || '').split(/\s+/).includes(m[1]);
  if ((m = s.match(/^\[([\w-]+)\]$/))) return el.hasAttribute(m[1]);
  if ((m = s.match(/^\[([\w-]+)="([^"]*)"\]$/))) return el.getAttribute(m[1]) === m[2];
  if ((m = s.match(/^\[([\w-]+)\*="([^"]*)"\]$/))) return (el.getAttribute(m[1]) || '').includes(m[2]);
  if (/^[a-z]+$/.test(s)) return el.tagName === s;
  throw new Error('fake DOM cannot match selector: ' + s);
}

// A Meet participant tile: a name label, plus the speaking marker when asked.
// Meet marks the local user's own tile with data-self-name.
function tile(name, { self = false, speaking = false } = {}) {
  const attrs = { 'data-participant-id': name };
  if (self) attrs['data-self-name'] = name;
  const kids = [new El('span', {}, [], name)];
  if (speaking) kids.push(new El('div', { class: 'IisKdb' }));
  return new El('div', attrs, kids);
}

// Objects built inside the sandbox have the sandbox's prototypes, so compare
// by value, not by deepStrictEqual.
const plain = (x) => JSON.stringify(x);

function loadContentScript(tiles) {
  const ctx = {
    document: new El('body', {}, tiles),
    location: { hostname: 'meet.google.com', pathname: '/abc-defg-hij' },
    setInterval: () => 0,
    fetch: () => Promise.resolve(),
    console,
  };
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'content.js'), 'utf8'), ctx);
  return ctx;
}

test('does not report the self tile, even when its speaking marker is lit', () => {
  const ctx = loadContentScript([tile('Geoff Counihan', { self: true, speaking: true })]);
  assert.equal(ctx.readMeetActiveSpeaker(), null);
});

test('a marker lit on every remote tile is no signal, not a room full of talkers', () => {
  const ctx = loadContentScript([
    tile('Alice', { speaking: true }), tile('Bob', { speaking: true }), tile('Carol', { speaking: true }),
  ]);
  assert.equal(ctx.readMeetActiveSpeaker(), null);
});

test('reports the one remote tile whose marker is lit', () => {
  const ctx = loadContentScript([tile('Alice', { speaking: true }), tile('Bob'), tile('Carol')]);
  assert.equal(plain(ctx.readMeetActiveSpeaker()), plain({ names: ['Alice'] }));
});

test('in a 1:1 call the remote tile is reported even when the self tile is lit too', () => {
  const ctx = loadContentScript([
    tile('Geoff Counihan', { self: true, speaking: true }), tile('Alice', { speaking: true }),
  ]);
  assert.equal(plain(ctx.readMeetActiveSpeaker()), plain({ names: ['Alice'] }));
});
