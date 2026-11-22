/**
 * Consumable reordering, as wired in.
 *
 * lib/consumable-reorder.js decides what to suggest. What can only go wrong HERE
 * is the chain a suggestion travels afterwards — suggest → draft PO → receive →
 * restock → expense — and every link of it was built for filament:
 *
 *   1. Receipt looks the PO's itemId up in `inventory`. A consumable is not
 *      there, so it restocks nothing, marks itself received, and the goods are
 *      paid for and absent from stock. Nothing errors.
 *   2. Quantities are grams. The receive dialog is captioned "(g)" and the
 *      expense divides by 1000 because filament is priced per kilo. A count of
 *      boxes through that arithmetic is off by three orders of magnitude.
 *   3. The expense is categorised `filament`, which inflates the material spend
 *      that pricing and the per-kilo analytics are derived from.
 *
 * Comments are stripped before matching: an assertion that passes by finding the
 * prose explaining a rule, rather than the rule, is one this repo has shipped
 * before.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
/** Drop // and /* *\/ comments so a rule can't be matched by its own explanation. */
const decomment = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');

const inv = decomment(read('renderer/inventory.js'));
const wire = decomment(read('renderer/wire-events.js'));
const html = read('renderer/index.html');

test('the module is loaded, or every call below is a ReferenceError', () => {
  assert.match(html, /<script src="\.\.\/lib\/consumable-reorder\.js"><\/script>/,
    'lib/consumable-reorder.js is never loaded');
});

// ───────────────────────────────────────────── the kind discriminator
//
// Drafting and receiving moved into `lib/purchase-orders.js` so the macOS app
// can have purchase orders at all. These used to read the renderer's source
// for the expressions; they drive the rule instead, and check that the
// renderer still goes through it.

const PO = require('../lib/purchase-orders.js');

test('a consumable PO is marked, and an unmarked one stays filament', () => {
  // Absent `kind` MUST read as filament: every PO written before this feature
  // has none, and the receive path restocks a different field on the answer.
  const cons = PO.draft({ item: { id: 'c-1', name: 'Glue', unit: 'pcs' },
                          ask: { kind: 'consumable' }, id: 'PO-1', today: 'T' });
  assert.equal(cons.kind, 'consumable');
  const fil = PO.draft({ item: { id: 'sp-1', material: 'PLA' }, ask: {}, id: 'PO-2', today: 'T' });
  assert.equal(fil.kind, undefined, 'a filament order carries no kind at all');
  assert.equal(PO.isConsumableOrder({ id: 'old' }), false, 'and an old order reads as filament');

  // An arbitrary kind is not written through, or an unknown value would route
  // the receipt nowhere.
  const odd = PO.draft({ item: { id: 'x' }, ask: { kind: 'sandwich' }, id: 'PO-3', today: 'T' });
  assert.equal(odd.kind, undefined);
});

test('a consumable PO carries the item\'s name and unit, not a material', () => {
  const cons = PO.draft({ item: { id: 'c-1', name: 'Glue stick', unit: 'pcs' },
                          ask: { kind: 'consumable' }, id: 'PO-1', today: 'T' });
  assert.equal(cons.itemName, 'Glue stick',
    'a consumable PO would be titled undefined — consumables have no .material');
  assert.equal(cons.unit, 'pcs', 'the unit is not carried, so receipt cannot label itself');
  assert.equal(cons.qty, 1, '1000 is a spool; it is not the default for a box of screws');

  const fil = PO.draft({ item: { id: 'sp-1', material: 'PLA Black' }, ask: {}, id: 'PO-2', today: 'T' });
  assert.equal(fil.itemName, 'PLA Black');
  assert.equal(fil.qty, 1000);

  // And the renderer asks the rule rather than drafting one of its own.
  assert.match(inv, /KhaytPurchaseOrders\.draft\(/,
    'createPurchaseOrder builds the record itself again');
});

// ────────────────────────────────────────────────── receiving the goods

test('a received consumable restocks the consumable, not a spool', () => {
  // The whole feature is worthless — worse than absent — if the goods arrive
  // and stock does not move.
  const out = PO.receive({
    po: { id: 'PO-1', kind: 'consumable', qty: 5, unitPrice: 2 },
    consumable: { id: 'c-1', stock: 1 },
    item: { id: 'sp-1', weight: 500, usageHistory: [] },   // must be left alone
    quantity: 5, today: 'T', expenseId: 'E',
  });
  assert.equal(out.consumable.stock, 6, 'the consumable is found and then not restocked');
  assert.equal(out.item, undefined, 'a consumable receipt touched a spool');

  // The spool path must survive untouched.
  const spool = PO.receive({
    po: { id: 'PO-2', qty: 100, unitPrice: 1 },
    item: { id: 'sp-1', weight: 500, usageHistory: [] },
    quantity: 100, today: 'T', expenseId: 'E2',
  });
  assert.equal(spool.item.weight, 600, 'the filament restock was lost in the refactor');
  assert.equal(spool.item.weight <= PO.MAX_SPOOL_GRAMS, true);

  // And the handler goes through the rule.
  const at = wire.indexOf("const recv    = e.target.closest('[data-act=\"po-receive\"]')");
  assert.ok(at > -1, 'the receive handler moved; this guard is anchored on it');
  assert.match(wire.slice(at, at + 4500), /KhaytPurchaseOrders\.receive\(/,
    'the receive handler restocks the shelf itself again');
});

test('the amount is asked for in the shop\'s unit, never captioned grams', () => {
  const at = wire.indexOf("const recv    = e.target.closest('[data-act=\"po-receive\"]')");
  const body = wire.slice(at, at + 4500);
  assert.match(body, /const unitLbl = isCons/, 'the unit label is not derived from the order');
  assert.doesNotMatch(body, /po\.weight_received'\)\}\s*\(g\)/,
    'the receive dialog is hard-captioned (g) — a count of boxes asked for in grams');
});

test('a consumable is not booked as filament spend', () => {
  // `filament` feeds the material cost that pricing and the per-kilo analytics
  // are built on. Glue in that number is a wrong number, not an untidy one.
  const cons = PO.receive({ po: { id: 'PO-1', kind: 'consumable', qty: 5, unitPrice: 3 },
                            consumable: { id: 'c-1', stock: 0 }, quantity: 5,
                            today: 'T', expenseId: 'E' });
  assert.equal(cons.expense.category, 'other', 'a box of bags is recorded as filament spend');
  assert.equal(cons.expense.amount, 15, "the expense is not priced off the order's own unit price");

  const fil = PO.receive({ po: { id: 'PO-2', qty: 1000, unitPrice: 0.085 },
                           item: { id: 'sp-1', weight: 0, usageHistory: [] },
                           quantity: 250, today: 'T', expenseId: 'E2' });
  assert.equal(fil.expense.category, 'filament');
  // Per GRAM, so there is no /1000: that division booked two halalahs for a
  // quarter-spool.
  assert.equal(fil.expense.amount, 21.25);

  const at = wire.indexOf("const recv    = e.target.closest('[data-act=\"po-receive\"]')");
  assert.doesNotMatch(wire.slice(at, at + 4500), /\/\s*1000/,
    'a per-kilo division survives somewhere in the receive handler');
});

test('completion is measured against what was actually ordered', () => {
  // po.weightOrdered was read here but never written by anything, so BOTH kinds
  // measured themselves against 0 and no order could ever reach `received`.
  const part = PO.receive({ po: { id: 'PO-1', qty: 1000 },
                            item: { id: 'sp-1', weight: 0, usageHistory: [] },
                            quantity: 400, today: 'T' });
  assert.equal(part.po.status, 'partial');
  assert.equal(part.po.receivedSoFar, 400);

  const done = PO.receive({ po: part.po, item: { id: 'sp-1', weight: 400, usageHistory: [] },
                            quantity: 600, today: '2026-09-19' });
  assert.equal(done.po.status, 'received', 'an order that is fully delivered never closes');
  assert.equal(done.po.receivedAt, '2026-09-19');
});

// ──────────────────────────────────────────────────── drafting the orders

test('consumables are deduped against consumable POs only', () => {
  // reorder.js's itemsNeedingDraftPo matches on itemId alone. Both id spaces
  // come from the same uid(), so sharing it would let an open consumable order
  // silence the reorder for an empty spool.
  assert.match(inv, /CR\.consumablesNeedingDraftPo\(csug, purchaseOrders\)/,
    'consumables are deduped with the filament matcher');
  const at = inv.indexOf('function maybeAutoDraftPurchaseOrders(');
  const body = inv.slice(at, inv.indexOf('\n}\n', at));
  assert.match(body, /KhaytConsumableReorder/, 'auto-draft never considers consumables');
  assert.match(body, /kind: 'consumable'/, 'the drafted PO is not marked as a consumable order');
});

test('the suggestion modal offers consumables and counts them in the button', () => {
  const at = inv.indexOf('function openReorderSuggestions(');
  const body = inv.slice(at, inv.indexOf('\n}\n', at));
  assert.match(body, /CR\.consumableSuggestions\(consumables, printLog/, 'the modal never asks for consumables');
  assert.match(body, /draftable\.length \+ cDraftable\.length/,
    'the draft button ignores consumables, so they are listed but cannot be ordered');
  assert.match(body, /consumableReorderText\(csug/, 'the copied list omits consumables');
});

test('a consumable quantity never renders under a grams heading', () => {
  const at = inv.indexOf('function openReorderSuggestions(');
  const body = inv.slice(at, inv.indexOf('\n}\n', at));
  // The consumable rows must go through qtyLabel, which appends the item's own
  // unit or nothing at all — never the ` g` the filament rows hard-code.
  const crows = body.slice(body.indexOf('const crows'), body.indexOf('const cDraftable'));
  assert.match(crows, /CR\.qtyLabel\(s\.stock, s\.unit\)/, 'stock is rendered without its unit');
  assert.doesNotMatch(crows, /\} g</, 'a consumable row hard-codes grams');
});

test('an empty filament list still shows the consumables that need ordering', () => {
  const at = inv.indexOf('function openReorderSuggestions(');
  const body = inv.slice(at, inv.indexOf('\n}\n', at));
  assert.match(body, /bodyHtml: \(sug\.length \|\| csug\.length\) \?/,
    'consumables are hidden whenever filament happens to be healthy');
});

test('the heading is translated everywhere', () => {
  for (const code of ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh']) {
    const loc = read(`renderer/locales/${code}.js`);
    assert.ok(loc.includes('"reorder.consumables":'), `${code} is missing reorder.consumables`);
  }
});
