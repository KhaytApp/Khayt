/**
 * The ledger that stops a customer telling the shop what they were quoted.
 *
 * A browser can put any JSON it likes in a POST body. If the price travelled
 * back through the customer, someone could file a request claiming the shop
 * quoted them 5 riyals for a two-day print — and the shop would read that number
 * off their own waiting list with nothing to say it was never theirs.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createEstimateLedger, DEFAULT_TTL_MS } = require('../lib/estimate-ledger.js');

const QUOTE = { ok: true, price: 113.77, currency: 'SAR', exact: true };

test('a remembered result comes back for the visitor it was issued to', () => {
  const L = createEstimateLedger();
  const ref = L.remember(QUOTE, '10.0.0.5');
  assert.deepEqual(L.recall(ref, '10.0.0.5'), QUOTE);
});

test('a reference is useless to a DIFFERENT visitor', () => {
  // The security property. Someone who sees a reference on a shared network must
  // not be able to staple that price onto their own request.
  const L = createEstimateLedger();
  const ref = L.remember(QUOTE, '10.0.0.5');
  assert.equal(L.recall(ref, '10.0.0.9'), null);
  assert.equal(L.recall(ref, ''), null);
  assert.equal(L.recall(ref, undefined), null);
  // …and still works for the rightful one afterwards.
  assert.deepEqual(L.recall(ref, '10.0.0.5'), QUOTE);
});

test('an unknown reference yields nothing', () => {
  const L = createEstimateLedger();
  L.remember(QUOTE, '10.0.0.5');
  for (const bad of ['est_made_up', '', null, undefined, 0, {}, []]) {
    assert.equal(L.recall(bad, '10.0.0.5'), null, JSON.stringify(bad));
  }
});

test('a reference expires', () => {
  let t = 1_000_000;
  const L = createEstimateLedger({ ttlMs: 1000, now: () => t });
  const ref = L.remember(QUOTE, 'ip');
  assert.deepEqual(L.recall(ref, 'ip'), QUOTE);
  t += 1001;
  assert.equal(L.recall(ref, 'ip'), null, 'past its TTL');
});

test('expired entries are swept, so the map does not grow forever', () => {
  // The endpoint is public. Without a sweep this is an unbounded allocation any
  // visitor can drive.
  let t = 0;
  const L = createEstimateLedger({ ttlMs: 100, now: () => t });
  for (let i = 0; i < 50; i++) { t += 1; L.remember(QUOTE, 'ip'); }
  assert.equal(L.size, 50);
  t += 1000;
  L.remember(QUOTE, 'ip');          // a write sweeps
  assert.equal(L.size, 1, 'the 50 stale entries are gone');
});

test('a recall past the TTL also drops the entry', () => {
  let t = 0;
  const L = createEstimateLedger({ ttlMs: 100, now: () => t });
  const ref = L.remember(QUOTE, 'ip');
  t = 500;
  L.recall(ref, 'ip');
  assert.equal(L.size, 0);
});

test('references are unique', () => {
  const L = createEstimateLedger();
  const seen = new Set();
  for (let i = 0; i < 200; i++) seen.add(L.remember(QUOTE, 'ip'));
  assert.equal(seen.size, 200, 'a collision would hand one visitor another\'s price');
});

test('the default TTL is hours, not days', () => {
  // Long enough to fill in a form, short enough that a price cannot be revived
  // next week after the shop changed its rates.
  assert.ok(DEFAULT_TTL_MS >= 60 * 60 * 1000);
  assert.ok(DEFAULT_TTL_MS <= 24 * 60 * 60 * 1000);
});
