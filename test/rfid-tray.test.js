'use strict';
/**
 * lib/rfid-tray.js: a Snapmaker U1 head's RFID tag, and which of the shop's
 * spools it is (U1 idea 2). The fixture is a logged read-only GET of a U1's
 * filament_detect (two Snapmaker-tagged heads, two without a tag; the tags'
 * card ids zeroed). Ideas only from bloodf/u1control; no code.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
for (const f of ['loaded-colours', 'spool-match', 'rfid-tray']) require('../lib/' + f + '.js');
const R = globalThis.KhaytRfidTray;
const FD = require('./fixtures/u1-filament-detect.json').result.status.filament_detect;

test('the U1 read: two tagged heads, two without a tag (an empty head reports white, and white is not a tag)', () => {
  const t = R.trays(FD);
  assert.equal(t.length, 4);
  assert.deepEqual(t[0], {
    vendor: 'Snapmaker', manufacturer: 'Polymaker', material: 'PLA', sub: 'SnapSpeed',
    colours: ['#080A0D'], weightG: 500, diameterMm: 1.75, lengthM: 150, sku: 900001, official: true,
  });
  assert.equal(t[1].colours[0], '#E2DEDB');
  assert.equal(t[2], null, 'VERSION 0 / NONE: no tag');
  assert.equal(t[3], null);
});

test('hexOf and the colour count: only COLOR_NUMS colours, packed ints only', () => {
  assert.equal(R.hexOf(526861), '#080A0D');
  assert.equal(R.hexOf(0), '#000000');
  for (const bad of [-1, 0x1000000, '526861', null, 1.5e9, NaN]) assert.equal(R.hexOf(bad), null, String(bad));
  const two = R.rfidTray({ VERSION: 1, MAIN_TYPE: 'PLA', COLOR_NUMS: 2, RGB_1: 0xFF0000, RGB_2: 0x0000FF, RGB_3: 0x00FF00 });
  assert.deepEqual(two.colours, ['#FF0000', '#0000FF']);
  assert.deepEqual(R.rfidTray({ VERSION: 1, MAIN_TYPE: 'PETG', COLOR_NUMS: 9, RGB_1: 0x123456 }).colours, ['#123456'], 'a count out of range reads one');
});

test('junk in, null out; nothing thrown', () => {
  for (const x of [null, undefined, 'x', 3, [], {}, { VERSION: 1 }, { VERSION: 1, MAIN_TYPE: 'none' }, { VERSION: 0, MAIN_TYPE: 'PLA' }]) {
    assert.equal(R.rfidTray(x), null, JSON.stringify(x));
  }
  assert.deepEqual(R.trays(null), []);
  assert.deepEqual(R.trays({ info: 'x' }), []);
  assert.equal(R.trays({ info: new Array(40).fill(null) }).length, 16, 'at most 16 heads read');
  const neg = R.rfidTray({ VERSION: 1, MAIN_TYPE: 'PLA', WEIGHT: -5, DIAMETER: 0, LENGTH: 'x', SKU: 0 });
  assert.equal(neg.weightG, null); assert.equal(neg.diameterMm, null); assert.equal(neg.lengthM, null); assert.equal(neg.sku, null);
});

const black = () => R.trays(FD)[0];
const spool = (id, over) => ({ id, material: 'PLA', color: '#0A0A0A', weight: 800, ...over });

test('spoolMatch: one strong match links', () => {
  const r = R.spoolMatch(black(), [spool('S1', { brand: 'Polymaker' }), spool('S2', { color: '#FFFFFF' }), spool('S3', { material: 'PETG' })]);
  assert.deepEqual(r, { action: 'link', spoolId: 'S1' });
});

test('spoolMatch: two strong matches, or only near shades, ask, best first (same brand, then colour)', () => {
  const r = R.spoolMatch(black(), [spool('S1'), spool('S2', { brand: 'Polymaker', color: '#101010' })]);
  assert.equal(r.action, 'ask');
  assert.deepEqual(r.candidates.map((c) => c.spoolId), ['S2', 'S1'], 'the same brand first');
  const near = R.spoolMatch(black(), [spool('S1', { color: '#2A2A35' })]);
  assert.equal(near.action, 'ask', 'a near shade is offered, never linked');
});

test('spoolMatch: another brand is never a strong match; used-up and resin spools are never offered', () => {
  assert.equal(R.spoolMatch(black(), [spool('S1', { brand: 'eSun' })]).action, 'ask');
  assert.equal(R.spoolMatch(black(), [spool('S1', { weight: 0 })]).action, 'new');
  assert.equal(R.spoolMatch(black(), [spool('S1', { materialType: 'resin' })]).action, 'new');
});

test('spoolMatch: nothing like it is "new", filled in from the tag; no tag is "none"', () => {
  const r = R.spoolMatch(black(), [spool('S1', { material: 'ABS' })]);
  assert.equal(r.action, 'new');
  assert.deepEqual(r.prefill, { material: 'PLA SnapSpeed', color: '#080A0D', brand: 'Polymaker', spoolWeight: 500, weight: 500, diameterMm: 1.75 });
  assert.deepEqual(R.spoolMatch(null, []), { action: 'none' });
  assert.deepEqual(R.spoolMatch(R.trays(FD)[2], []), { action: 'none' });
});

test('spoolMatch never changes a spool', () => {
  const spools = [spool('S1', { brand: 'Polymaker' }), spool('S2')];
  const before = JSON.stringify(spools);
  R.spoolMatch(black(), spools);
  R.spoolMatch(black(), []);
  assert.equal(JSON.stringify(spools), before);
});
