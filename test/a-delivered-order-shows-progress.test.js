'use strict';
/**
 * A customer who had received their print saw a tracker saying nothing started.
 *
 * The public order-status page carried its own list of stages, twice:
 *
 *     const STATUS_ORDER = ['quote', 'pending', 'on_hold', 'printing', 'post', 'completed'];
 *     const curIdx = STATUS_ORDER.indexOf(order.status);
 *
 * `qc` and `delivered` were in neither copy. `indexOf` returns -1, every step
 * then compares `-1 >= stepIndex` and comes out false:
 *
 *     order is qc         1 2 3 4 5   (0/5 steps reached)
 *     order is delivered  1 2 3 4 5   (0/5 steps reached)
 *
 * Delivered is the LAST thing that happens to an order. A customer opening that
 * page after their parcel arrived was shown a tracker with nothing marked.
 *
 * Two hand-kept copies of one enumeration, and the app assigns nine order
 * statuses while those lists knew six.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const P = require('../lib/order-progress.js');

const ROOT = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');
const src = read('renderer/integrations.js');

/** The tracker a customer would see, as five marks. */
const marks = (status) => P.STEPS.map((_, i) => (P.stepReached(status, i) ? '#' : '.')).join('');

test('a delivered order shows every step reached', () => {
  assert.equal(marks('delivered'), '#####', 'a customer with the print in hand sees an unstarted tracker');
});

test('an order in final checks is nearly done, not unstarted', () => {
  assert.equal(marks('qc'), '####.');
});

test('the ordinary path still reads correctly', () => {
  assert.equal(marks('quote'), '#....');
  assert.equal(marks('pending'), '##...');
  assert.equal(marks('printing'), '###..');
  assert.equal(marks('post'), '####.');
  assert.equal(marks('completed'), '#####');
});

test('on hold keeps what it reached', () => {
  // A held job has still got as far as it got; showing it as unstarted would be
  // the same lie in a smaller way.
  assert.equal(marks('on_hold'), '##...');
});

test('every status the app can assign is in the map', () => {
  // The bug was a status nobody added. This is the check that would have caught
  // it: read the assignments out of the source rather than keeping a list.
  const files = ['renderer', 'lib'].flatMap((d) => fs.readdirSync(path.join(ROOT, d))
    .filter((f) => f.endsWith('.js'))
    .map((f) => read(path.join(d, f))));
  const assigned = new Set();
  const KNOWN = new Set(Object.keys(P.PROGRESS_OF));
  for (const s of files) {
    // \b matters: without it, `po.status = 'received'` matches on the `o` and
    // drags PURCHASE ORDER statuses into a check about customer orders. My first
    // version did exactly that and reported `received` and `partial` as unknown
    // order statuses — a false alarm in the guard, which is how a guard gets
    // switched off.
    for (const m of s.matchAll(/\b(?:order|o|log|draft|rec)\.status\s*=\s*'([a-z_]+)'/g)) assigned.add(m[1]);
  }
  // A NET, NOT A CENSUS. Only literal assignments are visible statically —
  // `order.status = newStatus` is not, and neither is a status set through a
  // helper. That is fine for what this is for: a NEW status enters the codebase
  // as a literal somewhere, and this is where it gets noticed. The floor just
  // catches the regex being broken outright.
  assert.ok(assigned.size >= 3, `only ${assigned.size} assignments found — the sweep is broken`);
  const unknown = [...assigned].filter((s) => !KNOWN.has(s)).sort();
  assert.deepEqual(unknown, [],
    'an order status is assigned that lib/order-progress.js has never heard of — '
    + 'the customer tracker will mis-report it');
});

test('an unknown status fails forward, not backward', () => {
  // If one slips through anyway, "started" is the safe wrong answer. "Nothing
  // has happened" is what makes a customer think their order was lost.
  assert.equal(marks('something_new'), '##...');
  assert.equal(marks(''), '##...');
  assert.equal(marks(undefined), '##...');
});

test('neither copy of the page keeps its own list any more', () => {
  assert.ok(!/const STATUS_ORDER = \[/.test(src),
    'a local stage list is back — two copies of an enumeration is what caused this');
  assert.equal((src.match(/KhaytOrderProgress\.progressIndex\(order\.status\)/g) || []).length, 2,
    'both status pages must read the shared map');
  assert.equal((src.match(/KhaytOrderProgress\.stepReached\(order\.status, i\)/g) || []).length, 2);
});

test('the labels cover what the map covers', () => {
  // The fallback prints the raw key, so a gap here shows a customer "qc".
  for (const name of ['STATUS_LABELS', 'CLOUD_PORTAL_STATUS_LABELS']) {
    const at = src.indexOf(`${name} = {`);
    assert.ok(at > 0, `${name} is gone`);
    const block = src.slice(at, src.indexOf('};', at));
    const keys = [...block.matchAll(/(\w+):\s*'/g)].map((m) => m[1]);
    for (const st of ['qc', 'delivered', 'completed', 'printing']) {
      assert.ok(keys.includes(st), `${name} has no label for "${st}" — the raw key is shown to a customer`);
    }
  }
});

test('the module is loaded by both entry documents', () => {
  for (const html of ['renderer/index.html', 'renderer/bedready.html']) {
    assert.match(read(html), /<script src="\.\.\/lib\/order-progress\.js"><\/script>/,
      `${html} does not load lib/order-progress.js — the page would throw`);
  }
});
