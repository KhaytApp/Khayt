'use strict';
/**
 * The screen that reports the data file must not deny the limit exists.
 *
 * Settings said, in green, with a tick:
 *
 *     No size limit — file-based storage ✓
 *
 * There is a limit. main.js refuses to WRITE a store over 50 MB
 * (`hub:save-store`) and refuses to READ one (`recoverStoreRaw(50_000_000)`).
 * Past that line every save fails: the shop gets a toast, carries on working,
 * and loses the day at the next launch.
 *
 * A shop with a few thousand print files was reaching it — previews were about
 * nine tenths of what a record cost — and the one screen they would look at to
 * find out told them the opposite, in the colour that means "fine".
 *
 * The claim and the enforcement are read from the two files here, so they cannot
 * drift apart again: change the ceiling in main.js and this fails until the
 * screen agrees.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const mainJs = read('main.js');
const settings = read('renderer/settings.js');

/** Where renderStorageUsage lives, sliced to the next function. */
function usageBlock() {
  const at = settings.indexOf('async function renderStorageUsage()');
  assert.ok(at > -1, 'renderStorageUsage is gone');
  const rest = settings.slice(at + 10);
  const next = rest.search(/\n(?:async )?function [A-Za-z_$]/);
  return settings.slice(at, next === -1 ? settings.length : at + 10 + next);
}

test('the app still enforces a store ceiling on both sides', () => {
  // The number is one shared constant now (store-io owns it) so the daily
  // backup cannot refuse a store that saving accepts. Check the constant's
  // value and that both sides still gate on it — if either goes, the screen's
  // numbers become the fiction instead.
  const { MAX_STORE_BYTES } = require('../lib/store-io.js');
  assert.equal(MAX_STORE_BYTES, 50 * 1000 * 1000, 'the enforced ceiling moved');
  assert.match(mainJs, /if \(serialized\.length > MAX_STORE_BYTES\)/,
    'the write-side ceiling is gone — the screen now overstates the limit');
  assert.match(mainJs, /recoverStoreRaw\(MAX_STORE_BYTES\)/,
    'the read-side ceiling is gone');
});

/** Source with comments stripped — a guard that reads its own explanation of a
 *  bug as the bug is a guard that can never pass. This one matched the sentence
 *  quoted in the comment ABOVE the fix, which is the third time in this repo. */
function code(src) {
  return src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
}

test('Settings does not claim there is no limit', () => {
  assert.ok(!/No size limit/i.test(code(usageBlock())),
    'the storage panel still tells the shop there is no limit');
  assert.ok(!/no size limit/i.test(code(settings)),
    'the claim survives somewhere else in Settings');
});

test('the limit the screen shows is the limit main.js enforces', () => {
  const block = usageBlock();
  const m = block.match(/const LIMIT = ([\d *_]+);/);
  assert.ok(m, 'the panel no longer states a limit at all');
  // eslint-disable-next-line no-eval
  const shown = eval(m[1].replace(/_/g, ''));
  assert.equal(shown, require('../lib/store-io.js').MAX_STORE_BYTES,
    'the number on screen disagrees with the one main.js refuses at');
});

test('it changes colour before the wall, not after it', () => {
  /* A figure that is green at 49.9 MB and then simply stops working is not a
   * warning. The thresholds are what make this a warning rather than a readout. */
  const block = usageBlock();
  assert.match(block, /pct >= 90 \? 'var\(--danger\)'/, 'nothing turns red as the file fills');
  assert.match(block, /pct >= 70 \?/, 'nothing warns before the last tenth');
  assert.ok(block.includes('set.store_full'), 'there is no sentence for a nearly-full store');
  assert.ok(block.includes('set.store_filling'), 'there is no sentence for a filling store');
  // …and it says what to DO about it, not just that it is happening.
  const en = read('renderer/locales/en.js');
  assert.match(en, /"set\.store_full": "[^"]*Print Files[^"]*"/,
    'the warning does not say what would actually help');
});
