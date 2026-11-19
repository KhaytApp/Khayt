'use strict';
/**
 * A NEW desktop product carries its own rates, as the Mac's ProductSheet does
 * (Dev Hub, Nov 19): the shop's defaults at that moment
 * (KhaytPrintRates.defaultsFor), as numbers, so its labour is charged once.
 * An existing product is opened as it is: never given rates by opening or
 * saving it (Turki, Nov 19: it keeps its figures until "Use the new cost").
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const PR = require('../lib/print-rates.js');

const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'inventory.js'), 'utf8');
const at = src.indexOf('function openProductEditor(');
const body = src.slice(at, src.indexOf('\n}\n', at));

test('the new-product draft snapshots the shop defaults; the existing branch is a plain copy', () => {
  const m = body.match(/const draft = existing\s*\?\s*JSON\.parse\(JSON\.stringify\(existing\)\)\s*:\s*\{([\s\S]*?)\n {6}\};/);
  assert.ok(m, 'the draft literal');
  assert.match(m[1], /rates: window\.KhaytPrintRates\.defaultsFor\(/);
  assert.equal((body.match(/draft\.rates\s*=/g) || []).length, 0, 'nothing else writes rates on the draft');
});

test('defaultsFor gives every rate as a number, the shop tariff over Khayt\'s', () => {
  const d = PR.defaultsFor({ elecRate: 0.3 });
  for (const k of ['laborRate', 'prepTime', 'postTime', 'wearRate', 'powerDraw', 'elecRate', 'failureRate']) assert.equal(typeof d[k], 'number', k);
  assert.equal(d.elecRate, 0.3);
});
