const { test } = require('node:test');
const assert = require('node:assert/strict');
const { icon, hydrateIcons, PATHS } = require('../renderer/icons');

test('icon() returns inline SVG for a known name', () => {
  const out = icon('calendar');
  assert.match(out, /^<svg /);
  assert.match(out, /stroke="currentColor"/);        // inherits text colour, no baked hue
  assert.match(out, /aria-hidden="true"/);           // decorative, not announced
  assert.match(out, /width="15" height="15"/);       // default size
});

test('icon() honours a custom size, ignores nonsense', () => {
  assert.match(icon('printer', 20), /width="20" height="20"/);
  assert.match(icon('printer', 0), /width="15"/);    // 0 falls back to default
  assert.match(icon('printer', -5), /width="15"/);
});

test('icon() returns empty string for an unknown name — never a broken tag', () => {
  assert.equal(icon('no-such-glyph'), '');
  assert.equal(icon(), '');
  assert.equal(icon(null), '');
});

test('every declared glyph produces a well-formed single <svg>', () => {
  for (const name of Object.keys(PATHS)) {
    const out = icon(name);
    assert.equal((out.match(/<svg /g) || []).length, 1, `${name} should render one svg`);
    assert.ok(out.trim().endsWith('</svg>'), `${name} should be closed`);
  }
});

test('the queue toolbar names are all covered', () => {
  // If a toolbar button references a glyph this set does not have, it renders
  // nothing and silently loses its icon — assert the contract here.
  for (const name of ['calendar', 'schedule', 'clipboard', 'wand', 'monitor', 'play']) {
    assert.ok(PATHS[name], `missing glyph: ${name}`);
  }
});

/* ── hydrateIcons (DOM) ─────────────────────────────────────────── */

function fakeEl(attrs) {
  const store = { ...attrs };
  let html = '';
  return {
    getAttribute: (k) => (k in store ? store[k] : null),
    setAttribute: (k, v) => { store[k] = String(v); },
    insertAdjacentHTML: (_pos, s) => { html = s + html; },
    get _html() { return html; },
    get _attrs() { return store; },
  };
}

test('hydrateIcons fills matching elements once and marks them done', () => {
  const el = fakeEl({ 'data-khayt-icon': 'calendar' });
  const root = { querySelectorAll: (sel) => (sel.includes('data-khayt-icon') ? [el] : []) };
  hydrateIcons(root);
  assert.match(el._html, /^<svg /);
  assert.equal(el._attrs['data-icon-done'], '1');
});

test('hydrateIcons tolerates no root and no matches', () => {
  assert.doesNotThrow(() => hydrateIcons(null));
  assert.doesNotThrow(() => hydrateIcons({}));
  assert.doesNotThrow(() => hydrateIcons({ querySelectorAll: () => [] }));
});
