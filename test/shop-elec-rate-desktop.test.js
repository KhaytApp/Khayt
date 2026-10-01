'use strict';

/**
 * The shop's own electricity price (settings.elecRate, #1690) on the desktop:
 * the calculator opens on it, follows it when it changes unless someone typed
 * their own, and the fallbacks use it instead of a hardcoded 0.18.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const read = (f) => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');
const buildSrc = read('renderer/build.js');

function calc(settings, value) {
  const input = { value: String(value), dispatchEvent() {} };
  const ctx = vm.createContext({
    settings, Event: class { constructor(t) { this.type = t; } },
    document: { getElementById: (id) => (id === 'elecRate' ? input : null) },
    KhaytPrintRates: require('../lib/print-rates.js'),
  });
  const from = buildSrc.indexOf('function shopRateDefaults()');
  const to = buildSrc.indexOf('/** "📍 Auto"');
  vm.runInContext(buildSrc.slice(from, to) + '\nthis.api = { shopRateDefaults, seedCalcElecRate };', ctx);
  return { input, ...ctx.api };
}

test('the calculator opens on the shop\'s price, and Khayt\'s when it has none', () => {
  let c = calc({ elecRate: 0.32 }, '0.18');
  c.seedCalcElecRate(0.18);
  assert.equal(Number(c.input.value), 0.32);
  c = calc({}, '0.18');
  c.seedCalcElecRate(0.18);
  assert.equal(Number(c.input.value), 0.18);
});

test('a price someone typed into the calculator is kept', () => {
  const c = calc({ elecRate: 0.32 }, '0.5');
  c.seedCalcElecRate(0.18);
  assert.equal(c.input.value, '0.5');
});

test('changing the shop price moves a calculator still showing the old one, or empty', () => {
  let c = calc({ elecRate: 0.4 }, '0.32');
  c.seedCalcElecRate(0.32);
  assert.equal(Number(c.input.value), 0.4);
  c = calc({ elecRate: 0.4 }, '');
  c.seedCalcElecRate(0.32);
  assert.equal(Number(c.input.value), 0.4);
});

test('the fallbacks, the AI draft and the settings form all use the shop price', () => {
  assert.doesNotMatch(buildSrc, /num\(\$\('#elecRate'\)\.value,\s*0\.18\)/, 'no hardcoded 0.18 fallback in the calculator');
  assert.doesNotMatch(read('renderer/inventory.js'), /num\(\$\('#elecRate'\)\.value,\s*0\.18\)/);
  assert.match(buildSrc, /defaults: shopRateDefaults\(\)/);
  const settingsSrc = read('renderer/settings.js');
  assert.match(settingsSrc, /elecRate: opt\('#set_elecRate'\)/, 'goes through KhaytSettingsEdit.apply, which deletes a blank');
  assert.match(settingsSrc, /seedCalcElecRate\(elecBefore\)/);
  for (const page of ['renderer/index.html', 'renderer/bedready.html']) {
    assert.match(read(page), /<script src="\.\.\/lib\/print-rates\.js"><\/script>/, page);
  }
  assert.match(read('renderer/index.html'), /id="set_elecRate"/);
});

test('print-rates loads before settings-edit, which reads its bound', () => {
  for (const page of ['renderer/index.html', 'renderer/bedready.html']) {
    const src = read(page);
    const pr = src.indexOf('<script src="../lib/print-rates.js">');
    const se = src.indexOf('<script src="../lib/settings-edit.js">');
    assert.ok(pr > 0 && se > 0 && pr < se, page);
  }
});

test('a preset with a blank electricity rate gives the shop price, not 0', () => {
  assert.match(buildSrc, /String\(p\.elecRate\)\.trim\(\) === ''\) \? shopRateDefaults\(\)\.elecRate : p\.elecRate/);
});
