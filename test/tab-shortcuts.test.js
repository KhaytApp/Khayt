const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

/**
 * The single-key tab shortcuts used to live in a `switch` statement, with the
 * help modal listing them separately — two sources of truth that could drift,
 * so a key could be advertised but never honoured, or honoured and never shown.
 *
 * TAB_SHORTCUTS is now the handler AND what the sidebar hints are painted from.
 * These tests pin that it stays one map pointing at tabs that actually exist.
 */

const root = path.join(__dirname, '..');
const boot = fs.readFileSync(path.join(root, 'renderer', 'app-boot.js'), 'utf8');
const html = fs.readFileSync(path.join(root, 'renderer', 'index.html'), 'utf8');

/** Pull the literal out of the source rather than requiring a DOM-bound module. */
function shortcuts() {
  const m = boot.match(/const TAB_SHORTCUTS = \{([\s\S]*?)\};/);
  assert.ok(m, 'TAB_SHORTCUTS literal not found — did it get renamed?');
  const map = {};
  for (const line of m[1].split('\n')) {
    const kv = line.match(/^\s*([a-z]):\s*'([a-z-]+)',?\s*$/);
    if (kv) map[kv[1]] = kv[2];
  }
  return map;
}

test('every shortcut points at a tab that exists in the app', () => {
  const map = shortcuts();
  assert.ok(Object.keys(map).length >= 6, `parsed only ${Object.keys(map).length} shortcuts`);
  const missing = Object.entries(map)
    .filter(([, tab]) => !html.includes(`data-tab="${tab}"`))
    .map(([k, tab]) => `${k} → ${tab}`);
  assert.deepEqual(missing, [],
    `advertised on the sidebar but no such tab: ${missing.join(', ')}`);
});

test('no two keys claim the same tab, and no tab is claimed twice', () => {
  const map = shortcuts();
  const tabs = Object.values(map);
  assert.equal(new Set(tabs).size, tabs.length, `duplicate tab targets: ${tabs.join(', ')}`);
});

test('shortcuts do not collide with the reserved keys', () => {
  // '?' opens help and is handled before the map; a letter shortcut colliding
  // with it would be shadowed and silently never fire.
  const map = shortcuts();
  for (const key of Object.keys(map)) {
    assert.notEqual(key, '?', 'shadowed by the help handler');
    assert.match(key, /^[a-z]$/, `not a single lowercase letter: ${key}`);
  }
});

test('the handler reads the map rather than re-listing the keys', () => {
  // Guards the whole point: if someone reintroduces a switch, the hints and the
  // behaviour can disagree again and nothing else would catch it.
  assert.match(boot, /TAB_SHORTCUTS\[e\.key\.toLowerCase\(\)\]/,
    'the keydown handler no longer reads TAB_SHORTCUTS');
  assert.ok(!/case 'n': case 'N': switchTab/.test(boot),
    'the old switch statement is back — two sources of truth');
});

test('the sidebar hint is painted from the same map', () => {
  assert.match(boot, /function paintShortcutHints\(\)/, 'paintShortcutHints is gone');
  assert.match(boot, /Object\.entries\(TAB_SHORTCUTS\)/,
    'paintShortcutHints must derive from TAB_SHORTCUTS, not a hardcoded list');
  assert.match(boot, /aria-keyshortcuts/,
    'the shortcut must be exposed to assistive tech, not only drawn');
});
