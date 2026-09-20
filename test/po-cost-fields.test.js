/**
 * A purchase order has one quantity and one price, and everything downstream
 * must read those two.
 *
 * createPurchaseOrder writes `qty` and `unitPrice`. The receive handler was
 * written against `weightOrdered`, `unitCost` and `totalCost` — three names no
 * version of this app has ever written (checked with `git log -S` across the
 * whole history, back to the initial release). Nothing threw and nothing looked
 * wrong: the expense branch was simply never entered, so every auto-drafted
 * filament order restocked the spool and booked no expense at all. Goods paid
 * for, absent from material spend, and understating the per-kilo figures that
 * pricing is derived from.
 *
 * The same three names had leaked into the progress bar, the accountant's CSV
 * and — before it was fixed — the supplier-invoice discrepancy check, so the
 * broad guard below is the point of this file: it recomputes the set of fields
 * createPurchaseOrder actually writes by CALLING it, and fails on any field the
 * purchase-order code reads that is not in that set. A new silent-zero of this
 * shape trips it without anyone having to think of it.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8');
/** Drop comments so a rule can't be matched by the prose explaining it. */
const decomment = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');

require('../renderer/util.js');
require('../renderer/format.js');
// WHAT A PURCHASE ORDER IS is `lib/purchase-orders.js` now, shared with the
// macOS app. index.html loads it as a <script>; requiring it here does the same
// thing, so `createPurchaseOrder` below is the one that ships rather than one
// that throws for want of a global.
require('../lib/purchase-orders.js');
global.suppliers = [];
global.purchaseOrders = [];
const { createPurchaseOrder } = require('../renderer/inventory.js');

/** A filament order as the reorder paths draft it: grams, priced per gram. */
const filamentPo = () => createPurchaseOrder(
  { id: 'SPOOL-1', material: 'PLA Black', cost: 85, spoolWeight: 1000 },
  { qty: 750, unitPrice: 0.085, status: 'draft', silent: true },
);

/** A consumable order: the shop's own unit, priced per unit. */
const consumablePo = () => createPurchaseOrder(
  { id: 'CNS-GLUE', name: 'Glue stick', unit: 'pcs', cost: 3 },
  { kind: 'consumable', qty: 8, unitPrice: 3, status: 'draft', silent: true },
);

test('the real createPurchaseOrder prices an order as qty × unitPrice, both kinds', () => {
  const fil = filamentPo();
  assert.equal(fil.qty, 750, 'the quantity is stored as qty');
  assert.equal(fil.unitPrice, 0.085, 'the rate is stored as unitPrice');
  // The names the receive path used to read. Asserting their absence is the
  // whole point: they were plausible enough to be written into four call sites.
  assert.equal(fil.weightOrdered, undefined, 'weightOrdered is not a field a purchase order has');
  assert.equal(fil.unitCost, undefined, 'unitCost is not a field a purchase order has');
  assert.equal(fil.totalCost, undefined, 'totalCost is not a field a purchase order has');

  const con = consumablePo();
  assert.equal(con.kind, 'consumable');
  assert.equal(con.qty, 8);
  assert.equal(con.unitPrice, 3);
  assert.equal(con.unitCost, undefined, 'a consumable is priced the same way a spool is');
});

test('every purchase-order field the app reads is one createPurchaseOrder writes', () => {
  // Written = the keys the real function produces, for both kinds, plus the
  // fields the order picks up over its life (assigned as `po.x = …`). Nothing
  // is hand-listed, so this cannot drift out of date with the writer.
  const PO = require('../lib/purchase-orders.js');
  // Written = the keys the real functions produce. Drafting is one of them; the
  // other is RECEIVING, which adds `receivedSoFar` and stamps `receivedAt`.
  // Those arrive as keys of a returned record rather than as `po.x = …`, so a
  // sweep that only looked for assignment stopped seeing them the day the rule
  // moved out of the renderer — and reported a field the app has always
  // written as a silent zero.
  const receivedKeys = Object.keys(PO.receive({
    po: filamentPo(), item: { id: 'SPOOL-1', weight: 0, usageHistory: [] },
    quantity: 10, today: '2026-09-19', expenseId: 'EXP-1',
  }).po);
  // And the SUPPLIER'S BILL, which is the third writer. It moved out of the
  // renderer's save handler into `lib/supplier-invoice.js` for the same reason
  // receiving did — the Mac app records one too — so its keys are taken from
  // the real function here rather than hand-listed, exactly as above.
  const billKeys = Object.keys(
    require('../lib/supplier-invoice.js').record(filamentPo(),
                                                 { number: 'INV-1', amount: 63.75, date: '2026-09-19' }));
  const written = new Set([...Object.keys(filamentPo()), ...Object.keys(consumablePo()),
                           ...receivedKeys, ...billKeys]);

  // The purchase-order lifecycle: drafting, rendering, receiving, auditing.
  // lib/csv-bundle.js is deliberately absent — its `po.date`/`po.total` are ||
  // fallbacks for an externally-shaped snapshot, sitting behind the canonical
  // names, and the export is asserted behaviourally below instead.
  const FILES = ['renderer/inventory.js', 'renderer/wire-events.js', 'lib/po-audit.js',
                 'lib/purchase-orders.js', 'lib/supplier-invoice.js'];

  // A purchase order is never the paid one until something says so, and nothing
  // does: there is no "mark supplier invoice paid" control yet. Absent reads as
  // unpaid, which is the safe direction for an AP aging bar, so this is a
  // missing feature rather than a wrong number — unlike the fields above it.
  const KNOWN_UNWRITTEN = new Set(['invoicePaid']);

  const assigned = new Set();
  const reads = new Map();
  for (const rel of FILES) {
    const src = decomment(read(rel));
    for (const m of src.matchAll(/\bpo\.(\w+)\s*=(?![=>])/g)) assigned.add(m[1]);
    src.split('\n').forEach((line, i) => {
      // The negative lookbehind drops i18n keys — t('po.receive') is not a field.
      for (const m of line.matchAll(/(?<!['"])\bpo\.(\w+)/g)) {
        if (!reads.has(m[1])) reads.set(m[1], `${rel}:${i + 1}  ${line.trim()}`);
      }
    });
  }

  const known = new Set([...written, ...assigned, ...KNOWN_UNWRITTEN]);
  const dead = [...reads].filter(([field]) => !known.has(field)).map(([, where]) => where);
  assert.deepEqual(dead, [], `purchase-order fields read but never written — each is a silent zero:\n  ${dead.join('\n  ')}`);
});

test('receiving goods books the order\'s own unit price against what arrived', () => {
  // The expense arithmetic moved into `lib/purchase-orders.js` with the rest of
  // the receive chain, so it is driven here rather than read out of the
  // renderer. What the renderer must still do is GO THROUGH it.
  const PO = require('../lib/purchase-orders.js');
  const wire = decomment(read('renderer/wire-events.js'));
  const at = wire.indexOf("const recv    = e.target.closest('[data-act=\"po-receive\"]')");
  assert.ok(at > -1, 'the receive handler moved; this guard is anchored on it');
  const body = wire.slice(at, at + 4500);
  assert.match(body, /KhaytPurchaseOrders\.receive\(/,
    'the receive handler prices goods itself again instead of asking the rule');
  assert.doesNotMatch(body, /unitCost|totalCost|weightOrdered/,
    'a field no version of createPurchaseOrder writes is still read here');
  assert.doesNotMatch(body, /\/\s*1000/,
    'a per-kilo division survives somewhere in the receive handler');

  // 250 g of an 85/kg spool, priced per GRAM as the order carries it.
  const out = PO.receive({
    po: { id: 'PO-1', qty: 750, unitPrice: 0.085 },
    item: { id: 'SPOOL-1', weight: 0, usageHistory: [] },
    quantity: 250, today: '2026-09-19', expenseId: 'EXP-1',
  });
  assert.equal(out.expense.amount, 21.25, 'the true cost of 250 g');
  assert.equal(out.expense.category, 'filament');

  // The two ways it used to be wrong, kept as arithmetic so the numbers stay
  // in front of a reader.
  const w = 250, rate = 0.085;
  assert.equal(+(w * rate / 1000).toFixed(2), 0.02, 'the per-kilo formula, applied to a per-gram rate');
  assert.equal(+(w * (undefined || 0) / 1000).toFixed(2), 0, 'and what it actually booked: nothing');
});

test('the three places that price an order agree on one figure', () => {
  // Receipt, the supplier-invoice discrepancy check and the audit banner each
  // total an order independently. They disagreed for months because only one of
  // them read the fields the order carries.
  const po = filamentPo();
  const orderTotal = po.qty * po.unitPrice;

  // The invoice check used to be an expression inside the renderer's save
  // handler and this pinned its exact TEXT. It is `lib/supplier-invoice.js`
  // now, because the Mac app records a bill too — so what is pinned is the
  // FIGURE, which is what the test is named for and is a stronger claim than
  // the presence of a particular line.
  const SI = require('../lib/supplier-invoice.js');
  assert.equal(SI.expectedAmount(po), orderTotal,
    'the supplier-invoice check totals the order some other way');
  assert.equal(SI.expectedAmount({ qty: po.qty }), 0,
    'an order missing its unit price expects something, so every draft would flag');

  // And the renderer must GO THROUGH it rather than totalling the order again.
  const inv = decomment(read('renderer/inventory.js'));
  assert.match(inv, /KhaytSupplierInvoice\.record\(/,
    'the renderer decides for itself whether a supplier invoice matches');
  assert.doesNotMatch(inv, /const expectedAmt =/,
    'the old inline total is back beside the shared rule, free to disagree with it');

  const A = require('../lib/po-audit.js');
  const [suspect] = A.findSuspectPurchaseOrders(
    [{ ...po, unitPrice: 85 }],                       // a per-SPOOL price, the mistake it hunts
    [{ id: 'SPOOL-1', cost: 85, spoolWeight: 1000 }],
  );
  assert.ok(suspect, 'the audit no longer recognises the order it exists to flag');
  assert.equal(suspect.currentTotal, 750 * 85, 'the audit totals qty × unitPrice too');

  // Receiving the whole order books the whole order.
  assert.equal(+(po.qty * po.unitPrice).toFixed(2), +orderTotal.toFixed(2));
  assert.equal(+orderTotal.toFixed(2), 63.75, '750 g of an 85/kg spool');
});

test('the accountant\'s export carries a real purchase order\'s date and total', () => {
  const { buildCsvBundle } = require('../lib/csv-bundle.js');
  const po = filamentPo();
  const [file] = buildCsvBundle({ purchaseOrders: [po] });
  assert.equal(file.name, 'purchase-orders.csv');
  const [, row] = file.content.replace(/^﻿/, '').split('\r\n');

  assert.ok(row.includes(`"${po.orderedAt}"`), `the exported row has no date: ${row}`);
  assert.ok(row.includes('"63.75"'), `the exported row has no total: ${row}`);
  assert.equal(/,"",""$/.test(row), false, 'date and total export blank, as they did for every order');
});
