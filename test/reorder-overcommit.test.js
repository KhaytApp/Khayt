/**
 * overcommitWarnings (lib/reorder.js): the desktop's save-time "over-committed"
 * check, shared so the macOS app warns on the same sums.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const R = require('../lib/reorder.js');

const partGrams = (p) => ((+p.printWeight || 0) + (+p.supportWeight || 0)) * (+p.qty || 1);
const inv = [{ id: 's1', material: 'PLA Black', weight: 500 }, { id: 's2', material: 'PETG', weight: 200 }];

test('no warning while the spool covers open jobs plus the new parts', () => {
  const orders = [{ id: 'o1', status: 'queued', parts: [{ filamentId: 's1', printWeight: 200 }] }];
  const w = R.overcommitWarnings([{ filamentId: 's1', printWeight: 300 }], orders, inv, { partGrams });
  assert.deepEqual(w, []);
});

test('warns with what is left after the other open jobs', () => {
  const orders = [{ id: 'o1', status: 'printing', parts: [{ filamentId: 's1', printWeight: 400 }] }];
  const w = R.overcommitWarnings([{ filamentId: 's1', printWeight: 50, qty: 3 }], orders, inv, { partGrams });
  assert.equal(w.length, 1);
  assert.deepEqual(w[0], { spoolId: 's1', spoolName: 'PLA Black', needed: 150, available: 100 });
});

test('quotes, cancelled, finished and archived jobs reserve nothing', () => {
  const orders = ['quote', 'cancelled', 'completed', 'delivered'].map((status, i) =>
    ({ id: 'o' + i, status, parts: [{ filamentId: 's1', printWeight: 500 }] }));
  orders.push({ id: 'oa', status: 'queued', archived: true, parts: [{ filamentId: 's1', printWeight: 500 }] });
  assert.deepEqual(R.overcommitWarnings([{ filamentId: 's1', printWeight: 400 }], orders, inv, { partGrams }), []);
});

test('the job being edited does not count against itself', () => {
  const orders = [{ id: 'me', status: 'queued', parts: [{ filamentId: 's1', printWeight: 400 }] }];
  const parts = orders[0].parts;
  assert.equal(R.overcommitWarnings(parts, orders, inv, { partGrams }).length, 1);
  assert.deepEqual(R.overcommitWarnings(parts, orders, inv, { partGrams, excludeOrderId: 'me' }), []);
});

test('a multicolour part draws each colour from its own spool', () => {
  const part = { qty: 2, colours: [{ filamentId: 's1', grams: 10 }, { filamentId: 's2', grams: 120 }] };
  const w = R.overcommitWarnings([part], [], inv, { partGrams });
  assert.deepEqual(w.map(x => [x.spoolId, x.needed]), [['s2', 240]]);
  // and a colour part already queued reserves on the colour's spool
  const orders = [{ id: 'o1', status: 'queued', parts: [part] }];
  assert.equal(R.overcommitWarnings([{ filamentId: 's1', printWeight: 490 }], orders, inv, { partGrams }).length, 1);
});

test('spoolId wins over filamentId; unknown spools and empty parts are ignored', () => {
  const w = R.overcommitWarnings([{ spoolId: 's2', filamentId: 's1', printWeight: 300 }, null, { filamentId: 'gone', printWeight: 9e9 }], [], inv, { partGrams });
  assert.deepEqual(w.map(x => x.spoolId), ['s2']);
  assert.deepEqual(R.overcommitWarnings(null, null, null), []);
});
