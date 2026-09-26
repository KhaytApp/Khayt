'use strict';

/**
 * A captured webhook delivery cannot be replayed (SEC-010).
 *
 * Salla, Zid and the carriers sign the body only, so a delivery stays valid for
 * ever. The old guard forgot it after ten minutes, 500 newer deliveries or a
 * restart; this one remembers SHA-256(signature) for thirty days, in a file.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createReplayGuard, TTL_MS, MAX } = require('../lib/webhook-replay');

const memFile = () => { let text = null; return { load: () => text, save: (t) => { text = t; }, peek: () => text }; };
const T0 = Date.UTC(2026, 8, 26);

test('the same delivery is refused the second time, a different one is not', () => {
  const g = createReplayGuard();
  assert.equal(g.isReplay('sig-A', T0), false);
  assert.equal(g.isReplay('sig-A', T0 + 1000), true);
  assert.equal(g.isReplay('sig-B', T0 + 1000), false);
  assert.equal(g.isReplay('', T0), false, 'unsigned is refused upstream, not here');
});

test('the old ten-minute window is gone: a replay a day later is still refused', () => {
  const g = createReplayGuard();
  g.isReplay('sig-A', T0);
  assert.equal(g.isReplay('sig-A', T0 + 24 * 3600 * 1000), true);
  assert.equal(g.isReplay('sig-A', T0 + TTL_MS - 1), true);
});

test('a restart does not forget: a new guard over the same file still refuses it', () => {
  const file = memFile();
  createReplayGuard(file).isReplay('sig-A', T0);
  const afterRestart = createReplayGuard(file);
  assert.equal(afterRestart.isReplay('sig-A', T0 + 3600 * 1000), true);
});

test('the file holds a hash of the signature, never the signature', () => {
  const file = memFile();
  createReplayGuard(file).isReplay('very-secret-hmac-value', T0);
  assert.ok(!file.peek().includes('very-secret-hmac-value'));
  assert.match(file.peek(), /[0-9a-f]{64}/);
});

test('entries expire after thirty days, and the list is capped', () => {
  const g = createReplayGuard({ max: 3 });
  g.isReplay('a', T0); g.isReplay('b', T0 + 1); g.isReplay('c', T0 + 2); g.isReplay('d', T0 + 3);
  assert.equal(g.size(), 3, 'capped');
  assert.equal(g.isReplay('a', T0 + 4), false, 'the oldest went first');
  const h = createReplayGuard();
  h.isReplay('x', T0);
  assert.equal(h.isReplay('x', T0 + TTL_MS + 1), false, 'expired after thirty days');
  assert.equal(MAX, 10000);
});

test('a store that cannot be read or written never refuses a real delivery', () => {
  const broken = createReplayGuard({ load: () => '{not json', save: () => { throw new Error('disk full'); } });
  assert.equal(broken.isReplay('sig-A', T0), false);
  assert.equal(broken.isReplay('sig-A', T0 + 1), true, 'still protected in memory');
});

test('the desktop keeps the list beside the book, written by rename', () => {
  const lan = fs.readFileSync(path.join(__dirname, '..', 'lib', 'lan-server.js'), 'utf8');
  assert.match(lan, /function isReplayedWebhook\(signature, now = Date\.now\(\)\) \{\s*return _replayGuard\.isReplay\(signature, now\);/);
  assert.match(lan, /fs\.renameSync\(p \+ '\.tmp', p\)/);
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  assert.match(main, /webhookSeenPath: \(\) => path\.join\(app\.getPath\('userData'\), 'khayt-webhook-seen\.json'\)/);
});
