'use strict';
/**
 * The calculator's Edit → Update on a product part whose labour and packaging
 * are on the ORDER (money review of #2581, HIGH): the part came back from the
 * form without `orderLevelCosts` and `onceGroup`, was costed with labour and
 * packaging again (91.36 for 11.61) while the cart still carried the
 * product's 79.75, and lost its group, so removing it later left the
 * once-costs behind. The real build.js functions run here against a fake
 * form and the real cost library.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
for (const f of ['tax', 'pricing', 'order-money', 'order-payment', 'part-ids', 'print-rates', 'calculator-cost', 'product-price', 'product-pricing', 'order-new']) require('../lib/' + f + '.js');
const PP = globalThis.KhaytProductPricing, N = globalThis.KhaytOrderNew;

const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'build.js'), 'utf8');
const fn = (name) => { const at = src.indexOf('function ' + name + '('); assert.ok(at !== -1, name); return src.slice(at, src.indexOf('\n}\n', at) + 3); };

const rates = { laborRate: 90, prepTime: 0.25, postTime: 0.5, wearRate: 0.75, powerDraw: 150, elecRate: 0.18, failureRate: 10 };
const settings = { defaultMargin: 30, currency: 'SAR', defaultPackagingCost: 5 };
// The app's globals the cost library falls back to when the calculator calls it
// without a context (calculateLivePartCost), as renderer/build.js does.
globalThis.settings = settings; globalThis.inventory = [];
const product = { id: 'P', parts: [{ name: 'p0', printWeight: 100, printTime: 2, spoolCost: 90, spoolWeight: 1000, qty: 1 }], rates };

function cart() {
  const els = {};
  const el = (id) => (els[id] = els[id] || { id, value: '', dataset: {}, options: [{ text: 'PLA' }], selectedIndex: 0, textContent: '', style: {},
    dispatchEvent() {}, scrollIntoView() {} });
  const box = {
    console, Math, JSON, Number, String, Object, Array, Set, parseInt, isNaN, Event: function () {}, CustomEvent: function () {},
    settings, inventory: [], consumables: [],
    document: { getElementById: (id) => el(id), dispatchEvent() {} },
    $: (sel) => el(String(sel).replace(/^#/, '')),
    t: (k) => k, toast() {}, uid: (p) => p + Math.random().toString(36).slice(2, 8),
    num: (v, d) => (Number.isFinite(+v) && v !== '' ? +v : d), clampPositive: (v) => Math.max(0, +v || 0),
    applyPartExtras: (p) => p, renderBuild() {}, saveBuildDraft() {}, renderExtraMaterials() {}, renderColourLines() {},
    renderConsumableLines() {}, renderPriceTiers() {}, updateFailureRateHint() {}, renderOnceLine() {},
    computePartBaseCost: globalThis.KhaytCalculatorCost.computePartBaseCost,
    // The real modules, so the rule's branch runs (money review: a sandbox
    // without them skipped it, and passed with the switch flipped).
    KhaytCalculatorCost: globalThis.KhaytCalculatorCost, KhaytOrderMoney: globalThis.KhaytOrderMoney,
    currentBuild: [], currentFixedCosts: { labourCost: 0, packagingCost: 0 },
    currentExtraMaterials: [], currentPriceTiers: [], currentColourLines: [], currentPurgeGrams: 0, currentConsumableLines: [],
  };
  vm.createContext(box);
  vm.runInContext(['editingOnce', 'formPartMarked', 'formPerLine', 'calculateLivePartCost', 'snapshotPartFromForm', 'snapshotPartFromFormRaw', 'addPart', 'removePart', 'editPart', 'syncFixedCosts', 'onceFixedCost']
    .map(fn).join('\n') + '\nthis.api = { editPart, addPart, removePart, calculateLivePartCost, onceFixedCost, syncFixedCosts };', box);
  // The product added as appendProductParts does: its parts marked, one group.
  const jp = PP.productJobParts(product, { inventory: [], settings });
  box.currentBuild = jp.parts.map((p, i) => Object.assign({}, p, { id: 'PRT' + i, onceGroup: 'G1' }));
  box.currentFixedCosts = { labourCost: jp.labourCost, packagingCost: jp.packagingCost, groups: { G1: { labourCost: jp.labourCost, packagingCost: jp.packagingCost } } };
  return { box, api: box.api, el };
}
const logPrice = (box) => N.newOrder({ parts: box.currentBuild.map(({ onceGroup, ...p }) => p), labourCost: box.currentFixedCosts.labourCost,
  packagingCost: box.currentFixedCosts.packagingCost, project: 'J', margin: 30, asQuote: true },
{ settings, orders: [], clients: [], now: new Date('2026-11-19T08:00:00Z'), tokens: { tracking: new Uint8Array(16), quoteApproval: new Uint8Array(16), id: new Uint8Array(4) } }).price;

test('a product added and logged as it is: 118.77', () => {
  const { box } = cart();
  assert.equal(logPrice(box), 118.77);
});

test('Edit → Update (name only) keeps the mark and the group: the part is 11.61 and Log prices 118.77, not 222.44', () => {
  const { box, api } = cart();
  api.editPart(0);
  assert.ok(Math.abs(api.calculateLivePartCost() - 11.6094) < 0.0001, 'the live cost while editing: ' + api.calculateLivePartCost());
  box.$('#partName').value = 'renamed';
  api.addPart();
  const p = box.currentBuild[0];
  assert.equal(p.orderLevelCosts, true); assert.equal(p.onceGroup, 'G1'); assert.equal(p.id, 'PRT0');
  assert.ok(Math.abs(p.baseCost - 11.6094) < 0.0001, String(p.baseCost));
  assert.equal(logPrice(box), 118.77);
});

test('Edit → Update → Remove takes the product\'s once-costs with it', () => {
  const { box, api } = cart();
  api.editPart(0); api.addPart();
  api.removePart(0);
  assert.equal(api.onceFixedCost(), 0);
});

test('a manual part added after Update is not marked (the edit is over)', () => {
  const { box, api } = cart();
  api.editPart(0); api.addPart();
  box.$('#printWeight').value = '50'; box.$('#printTime').value = '1'; box.$('#laborRate').value = '90'; box.$('#prepTime').value = '0.25';
  api.addPart();
  assert.equal(box.currentBuild[1].orderLevelCosts, undefined);
  assert.ok(box.currentBuild[1].baseCost > 20, 'a manual part keeps its own labour');
});

// A hand part added to a cart that holds a product's once-costs, under the
// switch both ways: the cart stores what it costed, and Log == newOrder.
for (const flip of [false, true]) {
  test(`a hand part beside a product, switch ${flip}: stored as costed, and Log prices as newOrder`, () => {
    const Mo = globalThis.KhaytOrderMoney, CC = globalThis.KhaytCalculatorCost;
    const was = Mo.HAND_PARTS_SHARE_ONCE;
    try {
      Mo.HAND_PARTS_SHARE_ONCE = flip;
      const { box, api } = cart();
      Object.assign(box.$('#partName'), { value: 'hand' });
      for (const [k, v] of Object.entries({ printWeight: 50, printTime: 1, spoolCost: 90, spoolWeight: 1000, laborRate: 90, prepTime: 0.25, postTime: 0.5, failureRate: 10, partQty: 1 })) box.$('#' + k).value = String(v);
      api.addPart();
      const hand = box.currentBuild[1];
      assert.equal(hand.orderLevelCosts, flip ? true : undefined);
      // What the reports cost it at (no options) is what the cart stored.
      assert.ok(Math.abs(CC.partTotalCost(hand, { inventory: [], settings }) - hand.baseCost) < 0.0001, `stored ${hand.baseCost}`);
      assert.ok(flip ? hand.baseCost < 10 : hand.baseCost > 70, 'labour ' + (flip ? 'left out' : 'its own') + ': ' + hand.baseCost);
      const fresh = N.newOrder({ parts: box.currentBuild.map(({ onceGroup, ...p }) => JSON.parse(JSON.stringify(p))), labourCost: 74.25, packagingCost: 5.5, project: 'J', margin: 30, asQuote: true },
        { settings, orders: [], clients: [], now: new Date('2026-11-19T08:00:00Z'), tokens: { tracking: new Uint8Array(16), quoteApproval: new Uint8Array(16), id: new Uint8Array(4) } });
      assert.equal(logPrice(box), fresh.price);
    } finally { Mo.HAND_PARTS_SHARE_ONCE = was; }
  });
}

test('Edit, then the form cleared and Log: the part is gone, and so are its once-costs (Log syncs the groups)', () => {
  const { box, api } = cart();
  api.editPart(0);                                    // out of the cart, into the form
  box.$('#printWeight').value = ''; box.$('#printTime').value = '';   // abandoned
  api.syncFixedCosts();                               // what Log does first (order-flows.js)
  assert.equal(api.onceFixedCost(), 0);
});

/* ── labourPerLine through the form (money review of #2586, MED 3) ──────── */

const FORM = { printWeight: 100, printTime: 0, spoolCost: 90, spoolWeight: 1000, laborRate: 90, prepTime: 0.25, postTime: 0.5, wearRate: 0, powerDraw: 0, elecRate: 0, failureRate: 10, partQty: 10 };
const fillForm = (box) => { box.$('#partName').value = 'hand'; for (const [k, v] of Object.entries(FORM)) box.$('#' + k).value = String(v); };

test('a NEW part from the calculator is marked labourPerLine and costed prep once: (90 + 472.50 + 5) x 1.1 = 624.25', () => {
  const { box, api } = cart();
  box.currentBuild = []; box.currentFixedCosts = { labourCost: 0, packagingCost: 0 };
  fillForm(box);
  api.addPart();
  const p = box.currentBuild[0];
  assert.equal(p.labourPerLine, true);
  assert.equal(Math.round(p.baseCost * 100) / 100, 624.25);
});

test('an OLD part (unmarked) keeps the old sum through Edit → Update: 847.00, and stays unmarked', () => {
  const { box, api } = cart();
  const CC = globalThis.KhaytCalculatorCost;
  const old = { id: 'OLD1', name: 'old', printWeight: 100, printTime: 0, spoolCost: 90, spoolWeight: 1000, laborRate: 90, prepTime: 0.25, postTime: 0.5,
    wearRate: 0, powerDraw: 0, elecRate: 0, failureRate: 10, qty: 10 };
  old.baseCost = CC.partTotalCost(old, { inventory: [], settings });
  assert.equal(Math.round(old.baseCost * 100) / 100, 847);
  box.currentBuild = [old]; box.currentFixedCosts = { labourCost: 0, packagingCost: 0 };
  api.editPart(0);
  fillForm(box); box.$('#partName').value = 'renamed';
  api.addPart();
  const p = box.currentBuild[0];
  assert.equal(p.id, 'OLD1');
  assert.equal(p.labourPerLine, undefined, 'not moved to the new rule by an edit');
  assert.equal(Math.round(p.baseCost * 100) / 100, 847);
});

test('a marked part stays marked through Edit → Update', () => {
  const { box, api } = cart();
  box.currentBuild = []; box.currentFixedCosts = { labourCost: 0, packagingCost: 0 };
  fillForm(box); api.addPart();
  api.editPart(0); fillForm(box); api.addPart();
  assert.equal(box.currentBuild[0].labourPerLine, true);
  assert.equal(Math.round(box.currentBuild[0].baseCost * 100) / 100, 624.25);
});
