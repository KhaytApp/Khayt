'use strict';
/**
 * The shop-wide electricity tariff, `settings.elecRate`.
 *
 * Before it existed a tariff could only be written on a calculator preset, and
 * a preset applies only where one is picked — so a failed print, the power by
 * machine report, and a public quote on a preset that said nothing were all
 * charged Khayt's 0.18 (or, for the public quote, nothing at all).
 *
 * Precedence, lowest first: DEFAULTS → settings.elecRate → preset → machine →
 * part. An absent key is EXACTLY the behaviour from before it existed — that is
 * the no-migration promise, and the "absent" tests below hold it.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/tax.js');
require('../lib/spool-edit.js');
const R = require('../lib/print-rates.js');
const E = require('../lib/print-energy.js');
const F = require('../lib/failed-print-cost.js');
const { apply } = require('../lib/settings-edit.js');
const PQ = require('../lib/public-quote.js');
const QS = require('../lib/quote-sheet.js');
const { computePartBaseCost } = require('../lib/calculator-cost.js');
const { quoteTotal } = require('../lib/pricing.js');

// ── print-rates ─────────────────────────────────────────────────────────────

test('ratesFor: the shop tariff sits between Khayt\'s default and a preset', () => {
  const settings = { elecRate: 0.3 };
  assert.equal(R.ratesFor({}).elecRate, 0.18);
  assert.equal(R.ratesFor({ settings }).elecRate, 0.3);
  // A preset that says a tariff beats the shop's…
  assert.equal(R.ratesFor({ settings, preset: { elecRate: 0.25 } }).elecRate, 0.25);
  // …and one that says nothing leaves the shop's standing.
  assert.equal(R.ratesFor({ settings, preset: { wearRate: 2 } }).elecRate, 0.3);
  assert.equal(R.ratesFor({ settings, preset: { elecRate: '' } }).elecRate, 0.3);
  // A machine has no tariff of its own; the shop's goes through it.
  assert.equal(R.ratesFor({ settings, machine: { id: 'M1', powerDraw: 300 } }).elecRate, 0.3);
  // 0 is a real answer (a shop on solar), not "not said".
  assert.equal(R.ratesFor({ settings: { elecRate: 0 } }).elecRate, 0);
  // Only the tariff is read from settings.
  const other = R.ratesFor({ settings: { elecRate: 0.3, wearRate: 9, laborRate: 1 } });
  assert.equal(other.wearRate, R.DEFAULTS.wearRate);
  assert.equal(other.laborRate, R.DEFAULTS.laborRate);
});

test('ratesFor: blank, negative, NaN or a non-number tariff is "not said"', () => {
  for (const bad of ['', null, undefined, -0.1, NaN, Infinity, 'abc', {}]) {
    assert.equal(R.ratesFor({ settings: { elecRate: bad } }).elecRate, 0.18, String(bad));
    assert.equal(R.defaultsFor({ elecRate: bad }).elecRate, 0.18, String(bad));
  }
  assert.equal(R.ratesFor({ settings: { elecRate: '0.4' } }).elecRate, 0.4);
  assert.equal(R.ratesFor({ settings: null }).elecRate, 0.18);
});

test('ratesFor with no settings is exactly what it was', () => {
  const machine = { id: 'M1', powerDraw: 300, wearRate: 1.1 };
  const preset = { elecRate: 0.21, laborRate: 50 };
  assert.deepEqual(R.ratesFor({ machine, preset, settings: {} }), R.ratesFor({ machine, preset }));
  assert.deepEqual(R.ratesFor({ settings: {} }), Object.assign({}, R.DEFAULTS));
});

test('defaultsFor is pure: a fresh object, DEFAULTS untouched, no globals read', () => {
  const a = R.defaultsFor({ elecRate: 0.3 });
  const b = R.defaultsFor({ elecRate: 0.3 });
  assert.notEqual(a, b);
  assert.deepEqual(a, Object.assign({}, R.DEFAULTS, { elecRate: 0.3 }));
  a.elecRate = 99;
  assert.equal(R.DEFAULTS.elecRate, 0.18);
  assert.equal(R.defaultsFor({ elecRate: 0.3 }).elecRate, 0.3);
  assert.deepEqual(R.defaultsFor(), Object.assign({}, R.DEFAULTS));
  // A global named like settings changes nothing — the caller's settings rule.
  globalThis.settings = { elecRate: 7 };
  try { assert.equal(R.defaultsFor({}).elecRate, 0.18); } finally { delete globalThis.settings; }
});

test('the shop tariff costs a part', () => {
  const part = { qty: 1, printWeight: 0, printTime: 10, spoolCost: 0, spoolWeight: 1000 };
  const at = (settings) => computePartBaseCost(Object.assign({}, R.ratesFor({ settings }), part), { settings: {} });
  // 10 h × 0.15 kW × (0.3 − 0.18) = 0.18, plus the 10% failure allowance.
  assert.ok(Math.abs((at({ elecRate: 0.3 }) - at({})) - 0.198) < 1e-9);
});

// ── failed-print-cost & print-energy ────────────────────────────────────────

const MACHINE = { id: 'M1', wearRate: 1.5, powerDraw: 200 };
const JOB = { id: 'J1', machineId: 'M1', printTime: 8, parts: [{ printTime: 8 }] };

test('a failed print\'s power is charged the shop tariff — no preset needed', () => {
  const before = F.breakdown(JOB, { materialCost: 10, progress: 50 }, { machine: MACHINE });
  // 4 h × 0.2 kW × 0.18
  assert.equal(before.power, 0.14);
  const b = F.breakdown(JOB, { materialCost: 10, progress: 50 },
    { machine: MACHINE, settings: { elecRate: 0.3 } });
  // 4 h × 0.2 kW × 0.3 = 0.24
  assert.equal(b.power, 0.24);
  // A plug reading is charged the same tariff.
  const plug = F.breakdown(JOB, { materialCost: 10, energy: { wh: 1000, coverage: 1 } },
    { machine: MACHINE, settings: { elecRate: 0.3 } });
  assert.equal(plug.power, 0.3);
  // A preset still beats it, and a part's own beats both.
  assert.equal(F.breakdown(JOB, { materialCost: 10, progress: 50 },
    { machine: MACHINE, preset: { elecRate: 0.5 }, settings: { elecRate: 0.3 } }).power, 0.4);
  const priced = Object.assign({}, JOB, { parts: [{ printTime: 8, elecRate: 0.1 }] });
  assert.equal(F.breakdown(priced, { materialCost: 10, progress: 50 },
    { machine: MACHINE, settings: { elecRate: 0.3 } }).power, 0.08);
});

test('attach forwards the settings to the breakdown', () => {
  const row = F.attach({ cost: 10 }, JOB, { progress: 50 }, { machine: MACHINE, settings: { elecRate: 0.3 } });
  assert.equal(row.costPower, 0.24);
  assert.equal(row.cost, 10);
});

test('print-energy: tariffOf falls to the resolved rates, which carry the shop tariff', () => {
  const rates = R.ratesFor({ settings: { elecRate: 0.3 } });
  assert.equal(E.tariffOf({ parts: [{}] }, rates), 0.3);
  assert.equal(E.tariffOf({ parts: [{ elecRate: 0.2 }] }, rates), 0.2);
  assert.equal(E.tariffOf({ parts: [{}] }, R.ratesFor({})), 0.18);
  // powerByMachine prices the estimate at the shop's tariff.
  const orders = [{ id: 'J1', machineId: 'M1', status: 'completed', printTime: 10,
    actualEnergyWh: 2000, parts: [{ printTime: 10, powerDraw: 200 }] }];
  const rows = E.powerByMachine(orders, () => R.ratesFor({ machine: MACHINE, settings: { elecRate: 0.3 } }));
  assert.equal(rows.length, 1);
  // 2 kWh metered × 0.3
  assert.equal(rows[0].actCost, 0.6);
});

// ── settings-edit ───────────────────────────────────────────────────────────

test('settings-edit: elecRate is clamped 0–MAX_ELEC_RATE, blank deletes, junk and absence keep', () => {
  assert.equal(apply({}, { elecRate: 0.3 }).elecRate, 0.3);
  assert.equal(apply({}, { elecRate: '0.25' }).elecRate, 0.25);
  assert.equal(apply({}, { elecRate: -1 }).elecRate, 0);
  // A KRW or NGN shop's real tariff is stored as typed — the old 0–100 made it 100.
  assert.equal(apply({}, { elecRate: 250 }).elecRate, 250);
  assert.equal(apply({}, { elecRate: 500 }).elecRate, 500);
  assert.equal(apply({}, { elecRate: R.MAX_ELEC_RATE }).elecRate, R.MAX_ELEC_RATE);
  assert.equal(apply({}, { elecRate: 1e9 }).elecRate, R.MAX_ELEC_RATE);
  // Infinity and NaN are not numbers here: what was stored stays.
  assert.equal(apply({ elecRate: 0.3 }, { elecRate: Infinity }).elecRate, 0.3);
  assert.equal(apply({ elecRate: 0.3 }, { elecRate: NaN }).elecRate, 0.3);
  assert.equal(apply({}, { elecRate: 0 }).elecRate, 0);
  // Blank is "not said": the key goes, so the default applies again.
  assert.ok(!('elecRate' in apply({ elecRate: 0.3 }, { elecRate: '' })));
  assert.ok(!('elecRate' in apply({ elecRate: 0.3 }, { elecRate: '  ' })));
  assert.ok(!('elecRate' in apply({ elecRate: 0.3 }, { elecRate: null })));
  // Not a number keeps what was stored; a form without the field keeps it too.
  assert.equal(apply({ elecRate: 0.3 }, { elecRate: 'abc' }).elecRate, 0.3);
  assert.equal(apply({ elecRate: 0.3 }, { phone: '1' }).elecRate, 0.3);
  // A book that never had it does not grow one.
  assert.ok(!('elecRate' in apply({}, { phone: '1' })));
});

// ── public-quote & quote-sheet ──────────────────────────────────────────────
//
// THE BEHAVIOUR, PINNED. The public quote's tariff is the preset's own, else
// the shop's (settings.elecRate), else 0 — NOT Khayt's 0.18. A shop with no
// settings.elecRate is quoted exactly as before (0 for a preset without one).

const deps = { computePartBaseCost, quoteTotal };
const SLICED = { exact: true, source: 'slicer', printTimeMins: 600, filamentGrams: 100 };
const PRESET = { id: 'P1', wearRate: 0, powerDraw: 1000, laborRate: 0, failureRate: 0, prepTime: 0, postTime: 0 };
const store = (settings, preset) => ({
  settings: Object.assign({
    currency: 'SAR',
    lanApi: { intakeQuote: { enabled: true, presetId: 'P1', spoolCost: 100, spoolWeight: 1000, marginPct: 0 } },
  }, settings),
  printers: [Object.assign({}, PRESET, preset)],
  inventory: [],
});
const priceOf = (s) => PQ.publicQuote({ intake: SLICED, store: s, deps }).price;

test('public quote: a preset without a tariff is charged the shop\'s', () => {
  // 100 g at 0.1/g = 10; 10 h × 1 kW = 10 kWh.
  assert.equal(priceOf(store({}, {})), 10);                         // unchanged: 0 electricity
  assert.equal(priceOf(store({ elecRate: 0.3 }, {})), 13);          // the shop's 0.3
  assert.equal(priceOf(store({ elecRate: 0.3 }, { elecRate: '' })), 13);
  assert.equal(priceOf(store({ elecRate: 0.3 }, { elecRate: 0.5 })), 15); // the preset wins
  assert.equal(priceOf(store({}, { elecRate: 0.5 })), 15);
  assert.equal(priceOf(store({ elecRate: -1 }, {})), 10);           // junk is "not said"
  assert.equal(PQ.elecRateFor({}, {}), 0);
  assert.equal(PQ.elecRateFor(null, { elecRate: 0.3 }), 0.3);
});

test('quote sheet: carries the resolved tariff, so the storefront agrees with the LAN', () => {
  const book = store({ elecRate: 0.3 }, {});
  const sheet = QS.build(book, { now: new Date('2026-10-01T00:00:00Z') });
  assert.equal(sheet.printer.elecRate, 0.3);
  assert.equal(priceOf(QS.toStore(sheet)), priceOf(book));
  // A preset with its own keeps it; a book without the key publishes 0 as before.
  assert.equal(QS.build(store({ elecRate: 0.3 }, { elecRate: 0.5 }), {}).printer.elecRate, 0.5);
  assert.equal(QS.build(store({}, {}), {}).printer.elecRate, 0);
});

// ── ONE BOUND, EVERY READER ─────────────────────────────────────────────────
//
// settings.elecRate is per kWh in the shop's OWN currency, so the ceiling has
// to fit IQD/NGN/KRW. 10,000 — see lib/print-rates.js for the reasoning. Every
// reader clamps a stored value above it TO it (the shop did say a price), and
// refuses blank, negative, NaN, Infinity and junk as "not said".

test('MAX_ELEC_RATE is one figure: print-rates, settings-edit and public-quote agree', () => {
  assert.equal(R.MAX_ELEC_RATE, 10000);
  const SE = require('../lib/settings-edit.js');
  // The fallbacks used where print-rates is not loaded (the Electron renderer,
  // the storefront's vendored public-quote) are the same number.
  assert.equal(SE.ELEC_RATE_BOUND, R.MAX_ELEC_RATE);
  assert.equal(PQ.ELEC_RATE_BOUND, R.MAX_ELEC_RATE);
  // And it covers a real tariff in the weakest-unit currency Khayt prices in.
  const { CURRENCIES } = require('../lib/currencies.js');
  for (const code of ['IQD', 'NGN', 'KRW']) assert.ok(CURRENCIES && CURRENCIES[code], code);
});

test('readers clamp a stored tariff above the bound, and refuse junk', () => {
  const big = { elecRate: 250000 };
  assert.equal(R.shopTariff({ elecRate: 250 }), 250);
  assert.equal(R.shopTariff(big), R.MAX_ELEC_RATE);
  assert.equal(R.shopTariff({ elecRate: '250000' }), R.MAX_ELEC_RATE);
  assert.equal(R.ratesFor({ settings: big }).elecRate, R.MAX_ELEC_RATE);
  assert.equal(R.defaultsFor(big).elecRate, R.MAX_ELEC_RATE);
  assert.equal(PQ.elecRateFor({}, big), R.MAX_ELEC_RATE);
  assert.equal(PQ.elecRateFor({}, { elecRate: 250 }), 250);
  for (const bad of ['', '   ', '\t', null, undefined, -0.1, -500, NaN, Infinity, -Infinity, 'abc', {}, [], true]) {
    assert.equal(R.shopTariff({ elecRate: bad }), null, String(bad));
    assert.equal(R.ratesFor({ settings: { elecRate: bad } }).elecRate, 0.18, String(bad));
    assert.equal(PQ.elecRateFor({}, { elecRate: bad }), 0, String(bad));
  }
});

test('whitespace parity: a blank preset tariff defers, in ratesFor as in elecRateFor', () => {
  const settings = { elecRate: 0.3 };
  for (const blank of ['', ' ', '   ', '\t', '\n']) {
    // The preset step: blank is "not said", so the shop's tariff stands…
    assert.equal(R.ratesFor({ settings, preset: { elecRate: blank } }).elecRate, 0.3, JSON.stringify(blank));
    assert.equal(PQ.elecRateFor({ elecRate: blank }, settings), 0.3, JSON.stringify(blank));
    // …and with no shop tariff, Khayt's default (ratesFor) / 0 (public quote), never a free kWh by accident.
    assert.equal(R.ratesFor({ preset: { elecRate: blank } }).elecRate, 0.18, JSON.stringify(blank));
    // Every preset rate, and the machine's two, read blank the same way.
    const all = R.ratesFor({ preset: { wearRate: blank, laborRate: blank, failureRate: blank },
      machine: { powerDraw: blank, wearRate: blank } });
    assert.equal(all.wearRate, R.DEFAULTS.wearRate);
    assert.equal(all.laborRate, R.DEFAULTS.laborRate);
    assert.equal(all.failureRate, R.DEFAULTS.failureRate);
    assert.equal(all.powerDraw, R.DEFAULTS.powerDraw);
  }
  // A number with spaces round it is still that number, in both.
  assert.equal(R.ratesFor({ preset: { elecRate: ' 0.25 ' } }).elecRate, 0.25);
  assert.equal(PQ.elecRateFor({ elecRate: ' 0.25 ' }, settings), 0.25);
  // 0 said on a preset is a real answer in both.
  assert.equal(R.ratesFor({ settings, preset: { elecRate: 0 } }).elecRate, 0);
  assert.equal(PQ.elecRateFor({ elecRate: 0 }, settings), 0);
  assert.equal(R.ratesFor({ settings, preset: { elecRate: '0' } }).elecRate, 0);
  assert.equal(PQ.elecRateFor({ elecRate: '0' }, settings), 0);
});
