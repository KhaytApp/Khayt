'use strict';

/**
 * A tester's report, via the Mac lane: the desktop's Bambu PLA Matte colours
 * were wrong, and a multi-plate 3MF's plates never reached the screen.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const read = (f) => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');

const official = JSON.parse(read('scripts/filament-catalog-overrides.json')).filaments
  .find((f) => f.brand === 'Bambu Lab' && f.filament === 'PLA Matte').colours;

test('the catalogue the desktop browses has Bambu\'s 25 PLA Matte colours, by name and hex', () => {
  // renderer/filaments-db.json (whose matte list was invented) is gone: the
  // desktop reads assets/filament-catalog.json through lib/filament-catalog.js.
  const FC = require('../lib/filament-catalog.js');
  const cat = JSON.parse(read('assets/filament-catalog.json'));
  const matte = cat.filaments.find((f) => f.b === 'Bambu Lab' && f.n === 'PLA Matte');
  const got = FC.coloursOf(matte).map((c) => [c.name, c.hex]).sort();
  assert.deepEqual(got, official.map((c) => [c.name, c.hex]).sort());
  const basic = FC.coloursOf(cat.filaments.find((f) => f.b === 'Bambu Lab' && f.n === 'PLA Basic')).map((c) => c.name);
  for (const misfiled of ['Charcoal', 'Scarlet Red', 'Lemon Yellow']) assert.ok(!basic.includes(misfiled), `${misfiled} is a Matte colour`);
  assert.ok(!fs.existsSync(path.join(__dirname, '..', 'renderer', 'filaments-db.json')));
  assert.match(read('renderer/inventory.js'), /fetch\('\.\.\/assets\/filament-catalog\.json'\)/);
  for (const page of ['renderer/index.html', 'renderer/bedready.html']) assert.match(read(page), /lib\/filament-catalog\.js/, page);
});

test('the swatches agree: 25 Matte colours, no Matte Dark Gray, Basic Pink is its own colour', () => {
  const s = read('renderer/filament-swatches.js');
  const matte = [...s.matchAll(/brand: 'Bambu Lab', name: 'PLA Matte ([^']+)', material: 'PLA', hex: '(#[0-9A-F]{6})'/g)].map((m) => [m[1], m[2]]);
  assert.deepEqual(matte, official.map((c) => [c.name, c.hex]));
  assert.doesNotMatch(s, /PLA Matte Dark Gray/);
  assert.match(s, /name: 'PLA Basic Pink', material: 'PLA', hex: '#F55A74'/);
  assert.match(s, /name: 'PLA Basic Dark Gray', material: 'PLA', hex: '#545454'/);
});

test('plates reach the screen: main passes them, Print Files keeps and shows them, the calculator offers them', () => {
  const m = read('main.js');
  assert.equal((m.match(/plates: r\.plates,/g) || []).length, 1);
  assert.match(m, /result\.plates = r\.plates;/);
  const pf = read('renderer/printfiles.js');
  assert.match(pf, /rec\.parsed = Object\.assign\(\{\}, rec\.parsed, platesParsed\(p\)\);/);
  assert.match(pf, /\$\{platesHtml\(rec\)\}/);
  assert.match(pf, /async function rescanOldPlates\(\)/);
  assert.match(read('renderer/wire-events.js'), /showPlatePicker\(res, view\.weightG, view\.timeH\);/);
  for (const page of ['renderer/index.html', 'renderer/bedready.html']) assert.match(read(page), /id="calcPlateSelect"/, page);
});
