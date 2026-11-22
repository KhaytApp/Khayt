'use strict';
/**
 * Send to printer, checked first (Figma desktop page 129, S1/S1b/S1c):
 * renderer/send-checks-dialog.js says lib/send-checks.js's findings. The
 * frames' own sample data is the fixture, run through the real rule.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const SC = require('../lib/send-checks.js');
const en = (() => { const g = {}; new Function('globalThis', 'window', fs.readFileSync(path.join(__dirname, '../renderer/locales/en.js'), 'utf8'))(g, g); return g.KhaytLocales.en; })();
global.t = (k, v) => { let s = en[k] || k; for (const n of Object.keys(v || {})) s = s.split('{' + n + '}').join(String(v[n])); return s; };
const View = require('../renderer/send-checks-dialog.js');
const plain = (html) => String(html || '').replace(/<[^>]+>/g, '').replace(/&amp;/g, '&');

const u1 = { id: 'U1', name: 'Workshop U1', bed: { x: 270, y: 270, z: 270 }, toolheads: 4, printerApi: { type: 'moonraker' } };

test('S1: fits, a material mismatch, a bed nobody cleared, a head not reported', () => {
  const file = {
    name: 'bracket-kit-plate-2.gcode',
    bounds: { x: 182, y: 140, z: 30, source: 'placed-extents' },
    filaments: [{ slot: 2, type: 'PLA', colour: '#000000' }, { slot: 4, type: 'PLA', colour: '#FFFFFF' }],
  };
  const loaded = [{ slot: 1, hex: '#FFFFFF', material: 'PETG' }, { slot: 3, hex: null, material: 'NONE' }];
  const ended = Date.parse('2026-11-22T14:02:00');
  const live = { state: 'complete', lastActivityAt: ended };
  const findings = SC.sendChecks(file, u1, loaded, live, {});
  const rows = View.rows(findings, { printer: u1.name, bed: u1.bed, bounds: file.bounds, time: () => '14:02' });
  // lib/send-checks.js's order: worst first, then by tool (the bed has none).
  assert.deepEqual(rows.map((r) => r.code), ['fits', 'bed-not-cleared', 'material-mismatch', 'head-not-reported']);
  assert.deepEqual(rows.map((r) => r.kind), ['ok', 'warn', 'warn', 'info']);
  const by = (c) => rows.find((r) => r.code === c);
  assert.equal(plain(by('fits').title), 'Fits the bed: 182 × 140 mm on 270 × 270 mm');
  assert.match(plain(by('material-mismatch').title), /^Tool 2 has PETG\s+loaded; the file asks for PLA/);
  assert.match(by('material-mismatch').title, /class="sc-swatch" style="background:#FFFFFF"/);
  assert.equal(plain(by('bed-not-cleared').title),
    'The bed may not be clear: the last print ended at 14:02 and nobody has said the bed was cleared since');
  assert.equal(plain(by('bed-not-cleared').hint), 'Clear the bed, then press “Bed is clear”, or send anyway if it is clear.');
  assert.equal(plain(by('head-not-reported').title), 'Tool 4: the printer didn’t say what is loaded');
  assert.equal(plain(by('head-not-reported').hint), 'Not checked. Nothing is assumed.');
  assert.equal(SC.blocks(findings), false);
});

test('S1b: too big on the placed extents is a stop, and no "Fits" line', () => {
  const bounds = { x: 300, y: 210, z: 20, source: 'placed-extents' };
  const findings = SC.sendChecks({ bounds }, { ...u1, bed: { x: 270, y: 200, z: 270 } }, [], undefined, {});
  const rows = View.rows(findings, { printer: u1.name, bed: { x: 270, y: 200, z: 270 }, bounds });
  assert.equal(SC.blocks(findings), true);
  assert.deepEqual(rows.map((r) => r.kind), ['block']);
  assert.equal(plain(rows[0].title), 'Too big for this bed: 300 × 210 mm on 270 × 200 mm');
  assert.equal(plain(rows[0].hint), 'Slice it again for Workshop U1, or send it to a larger printer.');
});

test('S1c: measured from the moves only warns, and says so', () => {
  const bounds = { x: 285, y: 140, z: 20, source: 'toolpath' };
  const core = { id: 'CO', name: 'Prusa CORE One', bed: { x: 250, y: 220, z: 270 }, printerApi: { type: 'prusalink' } };
  const findings = SC.sendChecks({ bounds }, core, [], undefined, {});
  const rows = View.rows(findings, { printer: core.name, bed: core.bed, bounds });
  assert.equal(SC.blocks(findings), false);
  assert.deepEqual(rows.map((r) => r.kind), ['warn']);
  assert.equal(plain(rows[0].title), 'The printed area may not fit: 285 × 140 mm on 250 × 220 mm');
  assert.match(plain(rows[0].hint), /^Measured from the file’s moves/);
});

test('machine- and file-supplied text is escaped and isolated', () => {
  const rows = View.rows([{ code: 'sliced-for-other', severity: 'warn', model: '<img src=x>' }], { printer: 'A&B <b>' });
  assert.ok(!/<img/.test(rows[0].title) && /<bdi>&lt;img src=x&gt;<\/bdi>/.test(rows[0].title));
  assert.match(rows[0].hint, /<bdi>A&amp;B &lt;b&gt;<\/bdi>/);
});

test('every finding code has words, and an unknown one is left out', () => {
  for (const code of SC.CODES) {
    const r = View.rows([{ code, severity: 'warn', slot: 1, want: { type: 'PLA' }, have: { material: 'PETG' } }], {});
    assert.equal(r.length, 1, code);
    assert.ok(!/sc\./.test(r[0].title + (r[0].hint || '')), `${code} has no missing key`);
  }
  assert.equal(View.rows([{ code: 'something-new', severity: 'warn' }], {}).length, 0);
});

test('the file line: time and weight', () => {
  assert.equal(View.metaLine({ printTimeMins: 72, filamentGrams: 38.2 }), '1 h 12 min · 38 g');
  assert.equal(View.metaLine({ printTimeMins: 40 }), '40 min');
  assert.equal(View.metaLine({}), '');
});

test('every new string is in all nine languages', () => {
  const dir = path.join(__dirname, '../renderer/locales');
  const keys = Object.keys(en).filter((k) => k.startsWith('sc.') || k === 'mach.live_not_known' || k === 'mach.live_paused');
  assert.ok(keys.length >= 39);
  for (const f of fs.readdirSync(dir).filter((x) => x.endsWith('.js'))) {
    const g = {}; new Function('globalThis', 'window', fs.readFileSync(path.join(dir, f), 'utf8'))(g, g);
    const d = Object.values(g.KhaytLocales)[0];
    for (const k of keys) assert.ok(d[k], `${f} ${k}`);
  }
});
