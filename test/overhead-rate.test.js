'use strict';
/**
 * Overhead per print hour: the shop's monthly fixed costs, spread over the
 * hours it prints, as an OPT-IN cost line on a quote (lib/overhead-rate.js).
 *
 * Three kinds of test, because the bug this codebase keeps having is a correct
 * rule with no caller:
 *
 *   1. the rule — which costs, how many hours, and the guards;
 *   2. the money — `quoteTotal`, `newOrder`, `publicQuote` and the quote sheet,
 *      each with the line OFF (pinned unchanged) and ON;
 *   3. the callers — the Electron calculator's real `updateGrandTotal` and the
 *      real `logPrint`, run in a VM against a stubbed screen, so deleting the
 *      wiring fails here rather than passing a test of the helper alone.
 *
 * The Mac's callers are held by `OverheadTests` in the Swift package.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

require('../lib/depreciation.js');
require('../lib/pnl-report.js');
require('../lib/working-week.js');
const OH = require('../lib/overhead-rate.js');
const P = require('../lib/pricing.js');
const CC = require('../lib/calculator-cost.js');
const N = require('../lib/order-new.js');
const PQ = require('../lib/public-quote.js');
const QS = require('../lib/quote-sheet.js');
const SE = require('../lib/settings-edit.js');

const read = (f) => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');

const COSTS = [
  { id: 'a', name: 'Rent', amount: 1500 },
  { id: 'b', name: 'Internet', amount: 300 },
  { id: 'c', name: 'Fusion subscription', amount: 300 },
];
const SHOP = (over = {}) => ({ fixedCosts: COSTS, overheadPerHour: { enabled: true, monthlyHours: 500 }, ...over });

// ── 1. The rule ────────────────────────────────────────────────────────────

test('the rate is the monthly fixed costs over the shop\'s own monthly hours', () => {
  const r = OH.resolve({ settings: SHOP() });
  assert.equal(r.monthlyCost, 2100);
  assert.equal(r.hours, 500);
  assert.equal(r.source, 'shop');
  assert.equal(r.rate, 4.2);
  assert.equal(r.perHour, 4.2);
  assert.equal(r.reason, null);
  assert.equal(OH.perHour({ settings: SHOP() }), 4.2);
});

test('OFF — absent, or switched off — charges nothing, and still says what it would', () => {
  assert.equal(OH.perHour({ settings: { fixedCosts: COSTS } }), 0, 'every book written before this');
  const off = OH.resolve({ settings: SHOP({ overheadPerHour: { enabled: false, monthlyHours: 500 } }) });
  assert.equal(off.enabled, false);
  assert.equal(off.perHour, 0);
  assert.equal(off.rate, 4.2, 'the settings screen can show what turning it on would do');
  // Only a real `true` turns it on: a string from a hand-edited book is not consent.
  assert.equal(OH.perHour({ settings: SHOP({ overheadPerHour: { enabled: 'yes', monthlyHours: 500 } }) }), 0);
});

test('pay is left out — labour is its own line — and named', () => {
  const r = OH.resolve({ settings: SHOP({ fixedCosts: [...COSTS, { name: 'Staff salaries', amount: 4000 }, { name: 'رواتب', amount: 1000 }] }) });
  assert.equal(r.monthlyCost, 2100, 'the salaries are not spread over the print hours');
  assert.deepEqual(r.left.map((x) => x.name), ['Staff salaries', 'رواتب']);
  // The P&L's own words for pay, so the two cannot disagree.
  const Pnl = require('../lib/pnl-report.js');
  for (const row of r.left) assert.ok(Pnl.looksLikePayroll(row.name));
});

test('without a figure of its own, the hours come from the machines by the depreciation rule', () => {
  const settings = SHOP({ overheadPerHour: { enabled: true } });
  const machines = [
    { id: 'm1', targetHoursPerDay: 8 },                          // 8 × 365.25 ÷ 12 = 243.5
    { id: 'm2', depreciation: { price: 3000, monthlyHours: 200 } }, // typed on the machine
    { id: 'm3', targetHoursPerDay: 20, status: 'retired' },       // not printing any more
    { id: 'm4' },                                                 // nothing known: not counted
  ];
  const r = OH.resolve({ settings, machines, orders: [], today: '2026-10-15' });
  assert.equal(r.source, 'machines');
  assert.equal(r.hours, 443.5);
  assert.equal(r.rate, Math.round(2100 / 443.5 * 10000) / 10000);
  // The SAME per-machine figure depreciation charges wear over — not a second rule.
  const D = require('../lib/depreciation.js');
  assert.equal(r.hours, D.hoursPerMonth(machines[0], {}) + D.hoursPerMonth(machines[1], {}));
});

test('a machine\'s measured recent hours count when it has nothing typed', () => {
  const orders = [];
  for (let d = 1; d <= 30; d++) {
    orders.push({ status: 'completed', machineId: 'm1', date: `2026-10-${String(d % 15 + 1).padStart(2, '0')}`, printTime: 10 });
  }
  const r = OH.resolve({ settings: SHOP({ overheadPerHour: { enabled: true } }), machines: [{ id: 'm1' }], orders, today: '2026-10-15' });
  // 300 hours in the last 90 days → 300 ÷ 90 × 30.4375.
  assert.equal(r.hours, Math.round(300 / 90 * 30.4375 * 100) / 100);
  assert.ok(r.rate > 0);
});

test('guards: no costs, no hours, too few hours — no rate rather than an absurd one, and why', () => {
  assert.equal(OH.resolve({ settings: SHOP({ fixedCosts: [] }) }).reason, 'no_costs');
  assert.equal(OH.resolve({ settings: SHOP({ fixedCosts: [{ name: 'Wages', amount: 900 }] }) }).reason, 'no_costs',
    'pay alone is nothing to spread');
  assert.equal(OH.resolve({ settings: SHOP({ overheadPerHour: { enabled: true } }) }).reason, 'no_hours');
  // One idle machine: depreciation floors measured hours at ten a month, which
  // would put 210 an hour of rent on the next quote.
  const idle = OH.resolve({
    settings: SHOP({ overheadPerHour: { enabled: true } }),
    machines: [{ id: 'm1' }],
    orders: [{ status: 'completed', machineId: 'm1', date: '2026-10-01', printTime: 2 }],
    today: '2026-10-15',
  });
  assert.equal(idle.hours, 10);
  assert.equal(idle.reason, 'few_hours');
  assert.equal(idle.rate, null);
  assert.equal(idle.perHour, 0);
  const typedFew = OH.resolve({ settings: SHOP({ overheadPerHour: { enabled: true, monthlyHours: 5 } }) });
  assert.equal(typedFew.reason, 'few_hours');
  assert.equal(OH.resolve({ settings: SHOP({ overheadPerHour: { enabled: true, monthlyHours: 20 } }) }).rate, 105);
});

test('clean: what a stored value means', () => {
  assert.deepEqual(OH.clean(undefined), { enabled: false, monthlyHours: 0 });
  assert.deepEqual(OH.clean('on'), { enabled: false, monthlyHours: 0 });
  assert.deepEqual(OH.clean({ enabled: true, monthlyHours: -4 }), { enabled: true, monthlyHours: 0 });
  assert.deepEqual(OH.clean({ enabled: true, monthlyHours: 'abc' }), { enabled: true, monthlyHours: 0 });
  assert.deepEqual(OH.clean({ enabled: true, monthlyHours: 1e12 }), { enabled: true, monthlyHours: OH.MAX_MONTHLY_HOURS });
});

test('settings-edit: a form carrying the line saves it cleaned, one that does not keeps it', () => {
  const stored = { fixedCosts: COSTS, overheadPerHour: { enabled: true, monthlyHours: 300 } };
  const kept = SE.apply(stored, { phone: '0500' }, { year: 2026 });
  assert.deepEqual(kept.overheadPerHour, { enabled: true, monthlyHours: 300 });
  const turned = SE.apply(stored, { overheadPerHour: { enabled: false, monthlyHours: '-3' } }, { year: 2026 });
  assert.deepEqual(turned.overheadPerHour, { enabled: false, monthlyHours: 0 });
});

// ── 2. The money ───────────────────────────────────────────────────────────

test('quoteTotal: absent or zero overhead is the original arithmetic, to the last digit', () => {
  let seed = 7;
  const rnd = () => { seed = (seed * 16807) % 2147483647; return seed / 2147483647; };
  for (let i = 0; i < 2000; i++) {
    const input = {
      baseCost: rnd() * 500, margin: rnd() * 120, discountPct: rnd() * 30,
      rushEnabled: rnd() > 0.5, rushPct: 25, shippingCost: rnd() * 40,
      extraLines: rnd() > 0.5 ? [{ amount: rnd() * 20 }, { pct: rnd() * 8 }] : [],
      agreedAmount: rnd() > 0.7 ? rnd() * 100 : 0,
      priceRound: rnd() > 0.8 ? { step: 5, mode: 'nearest' } : null,
    };
    const before = P.quoteTotal(input);
    const zeroRate = P.quoteTotal({ ...input, overheadPerHour: 0, printHours: rnd() * 30 });
    const zeroHours = P.quoteTotal({ ...input, overheadPerHour: rnd() * 10, printHours: 0 });
    for (const after of [zeroRate, zeroHours]) {
      assert.equal(after.total, before.total);
      assert.equal(after.priceBeforeDiscount, before.priceBeforeDiscount);
      assert.equal(after.overhead, 0);
    }
  }
});

test('quoteTotal: ON, the overhead is a cost under the margin', () => {
  const q = P.quoteTotal({ baseCost: 100, margin: 50, overheadPerHour: 4.2, printHours: 10 });
  assert.equal(q.overhead, 42);
  assert.equal(q.priceBeforeDiscount, (100 + 42) * 1.5);
  assert.equal(q.total, 213);
  // A price tier replaces cost-plus-margin altogether: the overhead is still
  // reported as the cost it is, and does not move a fixed price.
  const tier = P.quoteTotal({ baseCost: 100, qty: 2, margin: 50, priceTier: { pricePerUnit: 80 }, overheadPerHour: 4.2, printHours: 10 });
  assert.equal(tier.total, 160);
  assert.equal(tier.overhead, 42);
  // Garbage is nothing, never Infinity.
  assert.equal(P.quoteTotal({ baseCost: 10, overheadPerHour: Infinity, printHours: 3 }).total, 10);
  assert.equal(P.quoteTotal({ baseCost: 10, overheadPerHour: -4, printHours: 3 }).total, 10);
});

const NOW = new Date('2026-10-15T09:00:00Z');
const TOKENS = { tracking: new Uint8Array(16).fill(1), quoteApproval: new Uint8Array(16).fill(2) };
const PART = (over = {}) => ({ name: 'Bracket', printWeight: 40, printTime: 3, qty: 2, unitCost: 20, baseCost: 40, ...over });
const job = (input) => N.newOrder({ parts: [PART()], margin: 50, ...input },
  { settings: { invNumNext: 1 }, orders: [], now: NOW, tokens: TOKENS });

test('newOrder: OFF, the record is the record it always was', () => {
  const plain = job({});
  const zero = job({ overheadPerHour: 0 });
  assert.deepEqual(zero, plain);
  assert.equal('overheadCost' in plain, false, 'no new key on a job without the line');
  assert.equal(plain.price, 60);
});

test('newOrder: ON, the price carries it, the record says so, the parts\' cost does not', () => {
  const on = job({ overheadPerHour: 4.2 });
  // 3 h × 2 pieces × 4.2 = 25.2, marked up 50% with the parts' 40.
  assert.equal(on.overheadCost, 25.2);
  assert.equal(on.price, +((40 + 25.2) * 1.5).toFixed(2));
  assert.equal(on.parts[0].baseCost, 40, 'the P&L counts fixed costs once, so the part cost stays pure');
  // An agreed part carries its agreed price and no overhead.
  const agreed = N.newOrder({ parts: [PART({ agreedPrice: 30 }), PART({ printTime: 1, qty: 1, baseCost: 10 })], margin: 0, overheadPerHour: 5 },
    { settings: {}, orders: [], now: NOW, tokens: TOKENS });
  assert.equal(N.overheadHours(agreed.parts), 1);
  assert.equal(agreed.overheadCost, 5);
  assert.equal(agreed.price, 30 * 2 + 10 + 5);
});

const PRESET = { id: 'P1', wearRate: 0.75, powerDraw: 150, elecRate: 0.18, laborRate: 90, failureRate: 10, prepTime: 0.25, postTime: 0.5 };
const SLICED = { exact: true, source: 'slicer', printTimeMins: 180, filamentGrams: 40 };
const book = (settingsOver = {}, more = {}) => ({
  settings: {
    currency: 'SAR', fixedCosts: COSTS,
    lanApi: { intakeQuote: { enabled: true, presetId: 'P1', spoolCost: 90, spoolWeight: 1000, marginPct: 40 } },
    ...settingsOver,
  },
  printers: [PRESET], inventory: [], printLog: [], machines: [{ id: 'm1', targetHoursPerDay: 8 }],
  ...more,
});
const deps = { computePartBaseCost: CC.computePartBaseCost, quoteTotal: P.quoteTotal };

test('publicQuote: OFF is the price it always was; ON a stranger is quoted the shop\'s overhead too', () => {
  const off = PQ.publicQuote({ intake: SLICED, store: book(), deps, qty: 2, today: '2026-10-15' });
  const before = PQ.publicQuote({ intake: SLICED, store: book({ fixedCosts: [] }), deps, qty: 2, today: '2026-10-15' });
  assert.equal(off.price, before.price, 'fixed costs alone, with the line off, change nothing');
  const on = PQ.publicQuote({ intake: SLICED, store: book({ overheadPerHour: { enabled: true, monthlyHours: 500 } }), deps, qty: 2, today: '2026-10-15' });
  // 3 h × 2 pieces × 4.2 = 25.2 of cost, marked up 40%.
  assert.equal(on.price, Math.round((off.price + 25.2 * 1.4) * 100) / 100);
  // From the machines when the shop typed no hours.
  const derived = PQ.publicQuote({ intake: SLICED, store: book({ overheadPerHour: { enabled: true } }), deps, qty: 1, today: '2026-10-15' });
  const offOne = PQ.publicQuote({ intake: SLICED, store: book(), deps, qty: 1, today: '2026-10-15' });
  assert.ok(derived.price > offOne.price);
});

test('quote sheet: the storefront\'s price equals the shop\'s, overhead and all — and a sheet without it is unchanged', () => {
  const estimatorOpts = {};
  const now = new Date('2026-10-15T10:00:00');
  const onBook = book({ overheadPerHour: { enabled: true, monthlyHours: 500 } });
  const sheet = QS.build(onBook, { now, staleAfterHours: 168, estimatorOpts });
  assert.equal(sheet.overheadPerHour, 4.2);
  const rebuilt = QS.toStore(JSON.parse(JSON.stringify(sheet)));
  const fromBook = PQ.publicQuote({ intake: SLICED, store: onBook, deps, qty: 3, today: '2026-10-15' });
  const fromSheet = PQ.publicQuote({ intake: SLICED, store: rebuilt, deps, qty: 3 });
  assert.equal(fromSheet.price, fromBook.price);
  const offSheet = QS.build(book(), { now, staleAfterHours: 168, estimatorOpts });
  assert.equal('overheadPerHour' in offSheet, false, 'a sheet from any other book is the sheet it was');
});

// ── 3. The callers ─────────────────────────────────────────────────────────

/** A top-level `function name(` out of a file, braces counted. */
function fnSource(file, name) {
  const src = read(file);
  const at = src.indexOf(`function ${name}(`);
  assert.ok(at >= 0, `${name} is in ${file}`);
  let depth = 0;
  for (let i = src.indexOf('{', at); i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(at, i + 1);
  }
  throw new Error(`unbalanced ${name}`);
}

/** The calculator screen, stubbed: every control a value, every output a sink. */
function calculatorContext(settings, form) {
  const els = {};
  const el = (id) => (els[id] = els[id] || {
    value: form[id] !== undefined ? String(form[id]) : '', checked: false, textContent: '', innerHTML: '',
    style: {}, getAttribute: () => 'polite', setAttribute() {}, querySelector: () => null,
  });
  const ctx = {
    settings, machines: [], printLog: [], currentBuild: [], currentPriceTiers: [], currentExtraLines: [],
    currentExtraMaterials: [], currentComponents: [], currentAssemblyQty: 1, consumables: [], lastQuote: null,
    $: (sel) => el(sel.replace(/^#/, '')),
    document: { querySelector: () => null, querySelectorAll: () => [] },
    window: {},
    populateCalcCurrency() {}, applyPartExtras: (p) => p, formHasPendingPart: () => false,
    computePartBreakdown: CC.computePartBreakdown,
    num: (v, f = 0) => { const n = parseFloat(v); return Number.isFinite(n) ? n : f; },
    clampPositive: (v) => { const n = parseFloat(v); return Number.isFinite(n) ? Math.max(0, n) : 0; },
    fmtMoney: (n) => (+n).toFixed(2), escapeHtml: (s) => String(s), t: (k) => k,
    localDateStr: () => '2026-10-15',
    KhaytPricing: P, KhaytOrderNew: N, KhaytOverheadRate: OH,
  };
  vm.createContext(ctx);
  vm.runInContext(fnSource('renderer/build.js', 'shopOverheadPerHour'), ctx);
  vm.runInContext(fnSource('renderer/build.js', 'updateGrandTotal'), ctx);
  return { ctx, els };
}

const FORM = {
  spoolCost: 90, spoolWeight: 1000, printWeight: 40, printTime: 3, wearRate: 0, powerDraw: 0, elecRate: 0,
  prepTime: 0, postTime: 0, laborRate: 0, failureRate: 0, partQty: 2, margin: 50, discountPct: 0, shippingCost: 0,
};

test('the Electron calculator\'s real updateGrandTotal: OFF unchanged, ON charges the overhead and shows the chip', () => {
  const off = calculatorContext({ fixedCosts: COSTS, mode: 'professional' }, FORM);
  off.ctx.updateGrandTotal();
  // 40 g × 0.09 = 3.6 a piece, × 2, + 50%.
  const r2 = (n) => Math.round(n * 100) / 100;
  assert.equal(r2(off.ctx.lastQuote.total), 10.8);
  assert.equal(off.ctx.lastQuote.overhead, 0);
  assert.doesNotMatch(off.els.costBreakdown.innerHTML, /calc\.bd\.overhead/);

  const on = calculatorContext(SHOP({ mode: 'professional' }), FORM);
  on.ctx.updateGrandTotal();
  // 3 h × 2 pieces × 4.2 = 25.2 on top of 7.2 of material, + 50%.
  assert.equal(r2(on.ctx.lastQuote.overhead), 25.2);
  assert.equal(r2(on.ctx.lastQuote.total), r2((7.2 + 25.2) * 1.5));
  assert.match(on.els.costBreakdown.innerHTML, /calc\.bd\.overhead/);
  // The part's own price line moves with it (per piece, × qty).
  assert.equal(on.els.partLivePrice.textContent, (((3.6 + 12.6) * 1.5) * 2).toFixed(2));
  // The margin shown is measured after the overhead: 1 − 32.4 ÷ 48.6.
  assert.match(on.els.marginWarning.innerHTML, /33% margin/);
});

test('the Electron calculator\'s real logPrint hands the job the rate the screen showed', () => {
  const STOP = new Error('captured');
  let captured = null;
  const { ctx } = calculatorContext(SHOP({ mode: 'professional' }), FORM);
  Object.assign(ctx, {
    currentBuild: [PART()], currentClientId: null, currentBuildFromProductId: null,
    addPart() {}, crypto: { getRandomValues: (b) => b },
    NewOrderRules: () => ({ TOKEN_BYTES: 16, newOrder: (input) => { captured = input; throw STOP; } }),
  });
  vm.runInContext(fnSource('renderer/order-flows.js', 'logPrint'), ctx);
  assert.throws(() => ctx.logPrint(false), (e) => e === STOP);
  assert.equal(captured.overheadPerHour, 4.2);
  // And 0 for a shop that has not turned it on.
  ctx.settings = { fixedCosts: COSTS, mode: 'professional' };
  assert.throws(() => ctx.logPrint(false), (e) => e === STOP);
  assert.equal(captured.overheadPerHour, 0);
});

test('every way a quote is computed is wired to the line (and the lib is loaded where it runs)', () => {
  for (const page of ['renderer/index.html', 'renderer/bedready.html']) {
    assert.match(read(page), /<script src="\.\.\/lib\/overhead-rate\.js"><\/script>/, page);
  }
  assert.match(read('mac/KhaytCore/Sources/KhaytCore/KhaytEngine.swift'), /^\s+"overhead-rate",$/m);
  // The LAN server prices strangers through publicQuote, which resolves the
  // rate itself; it must hand over the WHOLE store (machines and log in it).
  assert.match(read('lib/lan-server.js'), /const store = STORE\(\) \|\| \{\};\n\s+const quote = publicQuote\(\{\n\s+intake: read,\n\s+store,/);
});

test('the Electron settings card shows the rate and where it comes from, from the real functions', () => {
  const ctx = {
    settings: SHOP({ fixedCosts: [...COSTS, { name: 'Staff wages', amount: 3000 }] }),
    machines: [], printLog: [], KhaytOverheadRate: OH,
    localDateStr: () => '2026-10-15',
    fmtPrice: (n) => `${(+n).toFixed(2)} SAR`,
    fmtCount: (n) => (+n).toLocaleString('en-US'),
    escapeHtml: (s) => String(s),
    t: (k, vars) => (vars ? `${k}${JSON.stringify(vars)}` : k),
  };
  vm.createContext(ctx);
  for (const name of ['overheadResolved', 'overheadExplanation', 'overheadSettingsHtml']) {
    vm.runInContext(fnSource('renderer/settings.js', name), ctx);
  }
  const html = ctx.overheadSettingsHtml();
  assert.match(html, /id="ohEnabled" checked/);
  assert.match(html, /value="500"/);
  assert.match(html, /set\.overhead_rate\{"rate":"4\.20 SAR","cost":"2100\.00 SAR","hours":"500"\} · set\.overhead_src_shop/);
  assert.match(html, /set\.overhead_left\{"names":"Staff wages"\}/);
  ctx.settings = SHOP({ overheadPerHour: { enabled: false, monthlyHours: 5 } });
  const few = ctx.overheadSettingsHtml();
  assert.doesNotMatch(few, /id="ohEnabled" checked/);
  assert.match(few, /set\.overhead_few_hours\{"min":20,"hours":"5"\}/);
  // And the card is drawn by the fixed-costs section, which Settings renders.
  assert.match(fnSource('renderer/settings.js', 'renderFixedCostSettings'), /\$\{overheadSettingsHtml\(\)\}`;\n\s+wireOverheadSettings\(el\);/);
});
