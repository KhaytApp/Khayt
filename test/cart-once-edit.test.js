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
    currentBuild: [], currentFixedCosts: { labourCost: 0, packagingCost: 0 },
    currentExtraMaterials: [], currentPriceTiers: [], currentColourLines: [], currentPurgeGrams: 0, currentConsumableLines: [],
  };
  vm.createContext(box);
  vm.runInContext(['editingOnce', 'calculateLivePartCost', 'snapshotPartFromForm', 'snapshotPartFromFormRaw', 'addPart', 'removePart', 'editPart', 'syncFixedCosts', 'onceFixedCost']
    .map(fn).join('\n') + '\nthis.api = { editPart, addPart, removePart, calculateLivePartCost, onceFixedCost };', box);
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
