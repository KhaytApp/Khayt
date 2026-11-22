'use strict';
/**
 * A backup that fails must say so.
 *
 * Two faults, and the second hid the first.
 *
 * `hub:write-backup` refused any payload over 20 MB while `hub:save-store`
 * accepted 50 MB. A shop between those two numbers went on saving normally and
 * silently stopped being backed up — and the same 20 MB gate sat on the iCloud
 * copy, on restore points, and on the snapshot taken before an update, so every
 * safety net switched off together, at exactly the size where a shop has the
 * most to lose. The ceiling is one shared constant now; store-io owns it.
 *
 * `maybeAutoBackup` then threw the answer away. `writeBackup` returns
 * `{ok:false,error}` on refusal, nothing read it, and `updateLastBackupDisplay`
 * ran regardless — so Settings kept showing a date under "Last backup" as
 * though the net were still there.
 *
 * These drive the real function with a stubbed bridge rather than reading the
 * source, so deleting the check fails the test.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

/** Source with comments stripped, so a test cannot match prose about the bug. */
function code(p) {
  return read(p).replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');
}

/**
 * Run maybeAutoBackup against a fake bridge; returns what the shop would see.
 * Pass a previous `seen` to continue on the same screen — recovery can only be
 * tested from the warned state, never from a fresh one.
 */
async function runBackup({ writeBackup, lastBackup = '2020-01-01', seen: carried }) {
  const exp = require('../renderer/app-exports.js');
  const seen = carried || { toasts: [], label: lastBackup, colour: 'var(--text-dim)' };
  const el = {
    get textContent() { return seen.label; },
    set textContent(v) { seen.label = v; },
    style: { get color() { return seen.colour; }, set color(v) { seen.colour = v; } },
  };
  const prior = {};
  const g = globalThis;
  for (const k of ['settings', 'window', 'localDateStr', 'buildExportPayload', 't', 'toast', '$']) prior[k] = g[k];
  g.settings = { autoBackup: true, useIcloud: false };
  g.window = { hubAPI: { lastBackupDate: async () => seen.label, writeBackup } };
  g.localDateStr = () => '2026-09-03';
  g.buildExportPayload = () => ({});
  g.t = (k) => k;
  g.toast = (m, kind) => seen.toasts.push([m, kind]);
  g.$ = (sel) => (sel === '#lastBackupDate' ? el : null);
  const quiet = console.warn; console.warn = () => {};
  try { await exp.maybeAutoBackup(); } finally {
    console.warn = quiet;
    for (const k of Object.keys(prior)) g[k] = prior[k];
  }
  return seen;
}

test('a refused backup is reported, not swallowed', async () => {
  const seen = await runBackup({ writeBackup: async () => ({ ok: false, error: 'Backup data too large or invalid' }) });
  assert.deepEqual(seen.toasts, [['set.backup_failed', 'error']], 'the shop was never told');
  assert.equal(seen.label, 'set.backup_failed', 'Last backup still showed a date after a failure');
  assert.equal(seen.colour, 'var(--danger)');
});

test('a thrown backup is reported too', async () => {
  const seen = await runBackup({ writeBackup: async () => { throw new Error('disk full'); } });
  assert.deepEqual(seen.toasts, [['set.backup_failed', 'error']]);
  assert.equal(seen.label, 'set.backup_failed');
});

test('the next good backup clears the warning', async () => {
  // Start from the state a failure leaves behind, or this proves nothing.
  const seen = await runBackup({ writeBackup: async () => ({ ok: false, error: 'disk full' }) });
  assert.equal(seen.colour, 'var(--danger)', 'setup: expected the warned state');
  seen.toasts.length = 0;
  seen.label = '2020-01-01';
  await runBackup({ writeBackup: async () => ({ ok: true, path: '/x/2026-09-03.json' }), seen });
  assert.deepEqual(seen.toasts, [], 'a good backup must not alarm anyone');
  assert.equal(seen.colour, 'var(--text-dim)', 'the warning colour was left behind');
});

test('every safety net accepts a store as large as one that can be saved', () => {
  const { MAX_STORE_BYTES } = require('../lib/store-io.js');
  assert.equal(MAX_STORE_BYTES, 50_000_000);
  for (const f of ['main.js', 'lib/store-io.js', 'lib/updater.js']) {
    const src = code(f);
    assert.ok(!/\b20_000_000\b|\b20000000\b/.test(src),
      `${f} still has a 20 MB ceiling — a backup would refuse a store that saves fine`);
    // store-io holds the one definition; nobody else may write the number.
    const bare = (src.match(/\b50_000_000\b/g) || []).length;
    const allowed = f === 'lib/store-io.js' ? 1 : 0;
    assert.equal(bare, allowed, `${f} hardcodes the ceiling instead of importing MAX_STORE_BYTES`);
  }
});

test('the failure string exists in every locale', () => {
  const dir = path.join(root, 'renderer', 'locales');
  for (const f of fs.readdirSync(dir).filter((x) => x.endsWith('.js'))) {
    assert.ok(read(path.join('renderer', 'locales', f)).includes('"set.backup_failed"'),
      `${f} is missing set.backup_failed`);
  }
});
