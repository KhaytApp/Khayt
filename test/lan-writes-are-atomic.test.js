'use strict';
/**
 * Every LAN write goes through the chain, not around it.
 *
 * Each of the 17 endpoints that changed the store did it by hand: read the
 * in-memory copy, change one key, write the whole thing back. The read and the
 * enqueue sit in one synchronous block, so nothing interleaves THERE — but
 * `onStoreUpdated` only refreshes the in-memory copy after the awaited write
 * LANDS. A second request arriving while the first write is still in flight
 * reads the store as it was before the first change, and its write, queued
 * behind, puts that state back.
 *
 * Two tablets on the shop floor inside one write cycle: the order the first had
 * just logged was gone from disk, after the server had already answered 201.
 * Reproduced in test/store-io.test.js before the fix existed.
 *
 * This is a source guard rather than a behavioural one because the failure is
 * re-introduced by WRITING THE OLD SHAPE — the next endpoint added by copying a
 * neighbour. Behaviour is covered where the primitive lives.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
/** Source with comments stripped: a guard must not match prose describing the bug. */
const code = (p) => read(p).replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

test('no LAN endpoint writes the store outside the chain', () => {
  const lan = code('lib/lan-server.js');
  const calls = lan.match(/persistLanStoreUpdate\s*\(/g) || [];
  assert.deepEqual(calls, [],
    'a LAN endpoint writes the whole store from a copy it read earlier — '
    + 'use updateStoreOnDisk(mutate), which takes the read inside the write chain');
});

test('the LAN server is handed the atomic primitive', () => {
  const lan = code('lib/lan-server.js');
  assert.match(lan, /^\s*updateStoreOnDisk,$/m, 'lan-server no longer destructures updateStoreOnDisk');
  const main = code('main.js');
  assert.match(main, /^\s*updateStoreOnDisk,$/m, 'main.js no longer passes updateStoreOnDisk through');
  assert.match(main, /getStore: \(\) => lanServerStore/,
    'store-io has no way to read the current store inside the chain');
});

test('the background completion writer uses it too', () => {
  const main = code('main.js');
  const at = main.indexOf('async function persistCompletions()');
  assert.ok(at > 0, 'persistCompletions is gone');
  const body = main.slice(at, at + 1200);
  assert.match(body, /updateStoreOnDisk\(/, 'the completion timer writes a stale whole-store snapshot');
  assert.ok(!/persistLanStoreUpdate\(/.test(body), 'the completion timer still writes outside the chain');
});

test('the two storefront webhooks re-check for a duplicate inside the write', () => {
  // A provider retry arriving while the first write is in flight passes the
  // outer check — the log it reads has not been updated yet — so without the
  // inner one the same order is inserted twice.
  //
  // The re-check is `lib/storefront-webhook.js`'s `record` now, which both
  // servers call inside their write: so the handler must call it from inside
  // `updateStoreOnDisk`, and `record` must check before it inserts.
  const lan = code('lib/lan-server.js');
  for (const source of ['salla', 'zid']) {
    const at = lan.indexOf(`storefrontWebhook.record('${source}', parsed, cur`);
    assert.ok(at > 0, `the ${source} webhook does not record through the shared rule`);
    const write = lan.lastIndexOf('updateStoreOnDisk((cur)', at);
    assert.ok(write > 0 && at - write < 200,
      `the ${source} webhook records outside updateStoreOnDisk`);
  }
  const rule = code('lib/storefront-webhook.js');
  const recordFn = rule.slice(rule.indexOf('function record('));
  const check = recordFn.indexOf('alreadyRecorded(source, parsed, log)');
  const insert = recordFn.indexOf('log.unshift(');
  assert.ok(check > 0 && check < insert, 'record inserts before re-checking for a duplicate');
});

test('every mutator is synchronous', () => {
  // An `await` inside the mutator would pull the read and the write apart again
  // and reopen the window this whole change exists to close.
  const lan = read('lib/lan-server.js');
  const bad = [...lan.matchAll(/updateStoreOnDisk\(\s*async/g)];
  assert.equal(bad.length, 0, 'an async mutator reopens the race');
});
