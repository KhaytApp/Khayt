/**
 * The rates a print costs money at.
 *
 * The point of this file is the FIRST test. `lib/print-rates.js` exists because
 * the native Mac app was quoting jobs with material cost and nothing else — it
 * read five `settings.default*` keys that Khayt has never written anywhere, so
 * the fallback branch was the only branch, and wear, power, labour and the
 * failure allowance all came out zero. On a real 272g / 14.9h job that is 20.40
 * against the 109.40 Khayt's own calculator quotes: a five-fold underquote,
 * with nothing on screen to suggest it.
 *
 * The numbers therefore have to be the ones the calculator actually opens on,
 * and the only way to keep them so is to read them out of the form itself.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { DEFAULTS, ratesFor } = require('../lib/print-rates.js');
const { computePartBaseCost } = require('../lib/calculator-cost.js');

const HTML = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'index.html'), 'utf8');

/** The `value="…"` on `<input id="…">`, as the calculator ships it. */
function formDefault(id) {
  const tag = HTML.match(new RegExp(`<input[^>]*id="${id}"[^>]*>`));
  assert.ok(tag, `renderer/index.html has no input#${id} — the calculator has been rebuilt`);
  const value = tag[0].match(/value="([^"]*)"/);
  assert.ok(value, `input#${id} has no value attribute to default from`);
  return Number(value[1]);
}

test('every default is the figure the calculator form opens on', () => {
  for (const [key, expected] of Object.entries(DEFAULTS)) {
    assert.equal(formDefault(key), expected, `${key} has drifted from renderer/index.html`);
  }
});

test('the defaults are the whole set the cost model reads', () => {
  // A key added to the form and not here is a cost component that goes back to
  // being silently zero for every caller that is not the form.
  assert.deepEqual(Object.keys(DEFAULTS).sort(),
    ['elecRate', 'failureRate', 'laborRate', 'postTime', 'powerDraw', 'prepTime', 'wearRate']);
});

test('nothing supplied is the defaults, unchanged', () => {
  assert.deepEqual(ratesFor(), DEFAULTS);
  assert.deepEqual(ratesFor({}), DEFAULTS);
  assert.deepEqual(ratesFor({ machine: null, preset: undefined }), DEFAULTS);
});

test("a saved preset is the shop's own rates", () => {
  const out = ratesFor({ preset: { laborRate: 120, failureRate: 5, name: 'Bench' } });
  assert.equal(out.laborRate, 120);
  assert.equal(out.failureRate, 5);
  assert.equal(out.wearRate, DEFAULTS.wearRate, 'and the rest still come from Khayt');
});

/**
 * `applyMachineToCalculator` in renderer/build.js applies these two and only
 * these two, over everything else — "a machine carries the printer identity and
 * the one printer-specific cost input it knows".
 */
test('a machine overrides its power draw and its wear, and nothing else', () => {
  const out = ratesFor({
    preset: { powerDraw: 200, wearRate: 2, laborRate: 120 },
    machine: { powerDraw: 140, wearRate: 0.9, laborRate: 999, name: 'Snapmaker U1' },
  });
  assert.equal(out.powerDraw, 140);
  assert.equal(out.wearRate, 0.9);
  assert.equal(out.laborRate, 120, 'a machine has no opinion about what an hour of a person costs');
});

test('a machine that says nothing about its rates changes nothing', () => {
  // This shop's own U1 carries `powerDraw` and no `wearRate` at all.
  const out = ratesFor({ machine: { id: 'MACH-1', name: 'Snapmaker U1', powerDraw: 140 } });
  assert.equal(out.powerDraw, 140);
  assert.equal(out.wearRate, DEFAULTS.wearRate);
});

test('a rate of zero is a rate, and an empty one is not', () => {
  // A shop that genuinely pays nothing for electricity must be able to say so.
  assert.equal(ratesFor({ preset: { elecRate: 0 } }).elecRate, 0);
  // Blank, null and nonsense are "not set" — they must not zero a cost.
  for (const empty of ['', null, undefined, 'abc', NaN]) {
    assert.equal(ratesFor({ preset: { laborRate: empty } }).laborRate, DEFAULTS.laborRate,
      `${String(empty)} should mean "not set"`);
  }
});

test('the defaults cannot be edited by a caller', () => {
  const first = ratesFor();
  first.laborRate = 1;
  assert.equal(ratesFor().laborRate, DEFAULTS.laborRate, 'ratesFor handed out its own object');
  assert.throws(() => { 'use strict'; DEFAULTS.laborRate = 1; });
});

/**
 * The number that started it, kept as a number so a change to any of this is
 * visible as money rather than as a diff.
 */
test('a real job costs what Khayt says it costs, not a fifth of it', () => {
  const part = { printWeight: 272, printTime: 14.9, qty: 1, spoolCost: 75, spoolWeight: 1000 };
  const ctx = { inventory: [], settings: {} };

  const materialOnly = computePartBaseCost(part, ctx);
  assert.equal(Math.round(materialOnly * 100) / 100, 20.4);

  const proper = computePartBaseCost({ ...part, ...ratesFor() }, ctx);
  assert.equal(Math.round(proper * 100) / 100, 109.43);

  const onTheU1 = computePartBaseCost({ ...part, ...ratesFor({ machine: { powerDraw: 140 } }) }, ctx);
  assert.equal(Math.round(onTheU1 * 100) / 100, 109.4);
});
