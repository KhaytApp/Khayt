'use strict';
/**
 * lib/part-ids.js: the id a part without one is given, pinned exactly.
 *
 * Two computers that give the same book's parts their ids must write the same
 * ids, or sync sees two edits where there was one. So the hash, the key order
 * of the JSON it hashes, the way numbers are written and the separator are all
 * held here, and the vectors live in a file the Mac's test reads too
 * (`PartIdsParityTests`), so JavaScriptCore is held to what V8 says.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const P = require('../lib/part-ids.js');

const vectors = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'part-ids-vectors.json'), 'utf8'));

test('cyrb53 is the published algorithm (seed 0)', () => {
  // The value bryc's reference gives for "a"; written out here, not read from
  // the fixture, so a change to the hash cannot pass by regenerating the file.
  assert.equal(P.cyrb53('a', 0), 7929297801672961);
  for (const v of vectors.cyrb53) assert.equal(P.cyrb53(v.text, 0), v.hash, JSON.stringify(v.text));
});

test('the hashed text: order id, U+001F, index, U+001F, sorted JSON without the id', () => {
  assert.equal(
    P.idText('INV-2026-0001', 0, { qty: 2.0, name: 'Bracket', id: 'ignored', unitCost: 3 }),
    'INV-2026-0001\u001f0\u001f{"name":"Bracket","qty":2,"unitCost":3}');
  // Arabic is written as itself, not as \u escapes.
  assert.equal(P.stableJson({ name: 'حامل' }), '{"name":"حامل"}');
  // Undefined and functions are left out, as JSON.stringify leaves them out.
  assert.equal(P.stableJson({ b: undefined, a: 1, f() {} }), '{"a":1}');
});

test('every vector: the same text and the same id', () => {
  for (const c of vectors.cases) {
    assert.equal(P.idText(c.orderId, c.index, c.part), c.text, c.why);
    assert.equal(P.partIdFor(c.orderId, c.index, c.part), c.id, c.why);
    assert.match(c.id, /^PRT-[0-9a-z]{11}$/, c.why);
  }
  const byWhy = Object.fromEntries(vectors.cases.map((c) => [c.why, c.id]));
  assert.equal(byWhy['plain part'], byWhy['same part, keys in another order and 1.0 for 1: same id']);
  assert.notEqual(byWhy['plain part'], byWhy['same part at index 1: a different id']);
  assert.notEqual(byWhy['plain part'], byWhy['same part in another job: a different id']);
});

test('assignPartIds gives ids only to parts without one, and is idempotent', () => {
  const orders = [
    { id: 'INV-2026-0001', parts: [{ name: 'a', qty: 1 }, { id: 'PRT-keep', name: 'b' }, { id: '', name: 'c' }] },
    { id: 'INV-2026-0002', parts: [{ id: 'PRT-x', name: 'd' }] },
    { id: 'INV-2026-0003', parts: [null, 'text', 7] },
    { id: 'INV-2026-0004' },
  ];
  const given = P.assignPartIds(orders);
  assert.deepEqual(given, [
    { orderId: 'INV-2026-0001', index: 0, id: P.partIdFor('INV-2026-0001', 0, { name: 'a', qty: 1 }) },
    { orderId: 'INV-2026-0001', index: 2, id: P.partIdFor('INV-2026-0001', 2, { name: 'c' }) },
  ]);
  assert.equal(orders[0].parts[1].id, 'PRT-keep');
  assert.equal(orders[1].parts[0].id, 'PRT-x');
  assert.deepEqual(orders[2].parts, [null, 'text', 7]);
  const again = JSON.stringify(orders);
  assert.deepEqual(P.assignPartIds(orders), []);
  assert.equal(JSON.stringify(orders), again);
});

test('two computers, one book: the same ids', () => {
  const book = () => [{ id: 'INV-2026-0003-3y0z', parts: [{ name: 'حامل جوال', qty: 1, printWeight: 40 }] }];
  const a = book(), b = book();
  P.assignPartIds(a); P.assignPartIds(b);
  assert.deepEqual(a, b);
});

test('identical parts in one job get different ids', () => {
  const o = { id: 'J', parts: [{ name: 'x' }, { name: 'x' }] };
  P.assignOrder(o);
  assert.notEqual(o.parts[0].id, o.parts[1].id);
});

test('a made id another part of the job already holds gets -index', () => {
  const twin = { name: 'x' };
  const o = { id: 'J', parts: [{ id: P.partIdFor('J', 1, twin), name: 'y' }, { name: 'x' }] };
  P.assignOrder(o);
  assert.equal(o.parts[1].id, P.partIdFor('J', 1, twin) + '-1');
});

test('a standing order made without a host uid still gives its parts ids', () => {
  require('../lib/pricing.js'); require('../lib/working-week.js'); require('../lib/subscriptions.js');
  require('../lib/order-new.js');
  const R = require('../lib/recurring-orders.js');
  const settings = { invNumNext: 3, invNumYear: 2026, invPrefix: 'INV' };
  const job = R.clone({ id: 'T', parts: [{ id: 'PRT-old', name: 'a' }, { name: 'b' }] },
    { settings, now: new Date('2026-11-16T08:00:00Z'), cycle: '2026-11-16' });
  // freshPart drops the template's id (two jobs must not share one).
  assert.equal(job.parts[0].id, P.partIdFor(job.id, 0, { name: 'a' }));
  assert.equal(job.parts[1].id, P.partIdFor(job.id, 1, { name: 'b' }));
});
