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
    colours: ['#080A0D'], weightG: 500, diameterMm: 1.75, lengthM: 150, sku: 900001, official: true, uid: null,
  });
  assert.equal(t[1].colours[0], '#E2DEDB');
  assert.equal(t[2], null, 'VERSION 0 / NONE: no tag');
  assert.equal(t[3], null);
});

test('hexOf and the colour count: only COLOR_NUMS colours, a packed int or the same written as text', () => {
  assert.equal(R.hexOf(526861), '#080A0D');
  assert.equal(R.hexOf(0), '#000000');
  // Some readers send the number as text: it is the same colour (Nov 27, the extended firmware's notes).
  assert.equal(R.hexOf('526861'), '#080A0D');
  for (const bad of [-1, 0x1000000, '52x861', '', null, 1.5e9, NaN]) assert.equal(R.hexOf(bad), null, String(bad));
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

// ── The tag's id, and the shapes the U1 Extended Firmware adds (Nov 27 2026) ──

test('uidOf: CARD_UID bytes as one hex string; junk and all-zero are no id', () => {
  assert.equal(R.uidOf([112, 175, 145, 226]), '70AF91E2');
  assert.equal(R.uidOf([144, 187, 145, 226]), '90BB91E2');
  assert.equal(R.uidOf('70af91e2'), '70AF91E2');
  assert.equal(R.uidOf(['112', '175', '145', '226']), '70AF91E2', 'bytes written as text');
  for (const bad of [[], [0, 0, 0, 0], [256], [-1], 'zz', null, 7, new Array(17).fill(1)]) assert.equal(R.uidOf(bad), null, JSON.stringify(bad));
});

test('a reel with a tag on each flange: either uid finds the spool once both are kept', () => {
  // Turki's one spool read [112,175,145,226] in head 1 and [144,187,145,226] in head 2.
  const spool = R.withTagUid(R.withTagUid({ id: 'S1', material: 'PLA', color: '#080A0D', weight: 500 }, [112, 175, 145, 226]), '90BB91E2');
  assert.deepEqual(spool.tagUids, ['70AF91E2', '90BB91E2']);
  const tray = R.rfidTray({ VERSION: 1, MAIN_TYPE: 'PLA', RGB_1: 526861, CARD_UID: [144, 187, 145, 226] });
  assert.deepEqual(R.spoolMatch(tray, [spool, { id: 'S2', material: 'PLA', color: '#080A0D', weight: 500 }]), { action: 'link', spoolId: 'S1', by: 'uid' });
});

test('a uid no spool holds proves nothing: the match goes on by material, colour and maker', () => {
  const spools = [{ id: 'S1', material: 'PLA', color: '#080A0D', weight: 500, tagUids: ['70AF91E2'] }];
  const tray = R.rfidTray({ VERSION: 1, MAIN_TYPE: 'PLA', RGB_1: 526861, CARD_UID: [1, 2, 3, 4] });
  assert.deepEqual(R.spoolMatch(tray, spools), { action: 'link', spoolId: 'S1' }, 'still the same black PLA by colour');
});

test('withTagUid never changes the spool given, and adds a uid once', () => {
  const s = { id: 'S1', tagUids: ['70af91e2'] };
  assert.equal(R.withTagUid(s, '70AF91E2'), s, 'already held, case aside');
  assert.equal(R.withTagUid(s, [0, 0]), s, 'not a uid');
  const t = R.withTagUid(s, [1, 2, 3, 4]);
  assert.deepEqual(t.tagUids, ['70AF91E2', '01020304']);
  assert.deepEqual(s.tagUids, ['70af91e2']);
});

test('a "UID only" tag (no filament data): no tag to show, but its uid still finds the spool linked to it', () => {
  const info = { VERSION: 1, MAIN_TYPE: 'NONE', OFFICIAL: false, CARD_UID: [112, 175, 145, 226], CARD_TYPE: 'M1' };
  assert.equal(R.rfidTray(info), null);
  assert.equal(R.headUid(info), '70AF91E2');
  const spools = [{ id: 'S1', material: 'PLA', weight: 500, tagUids: ['70AF91E2'] }];
  assert.deepEqual(R.spoolMatch(null, spools, { uid: R.headUid(info) }), { action: 'link', spoolId: 'S1', by: 'uid' });
  assert.deepEqual(R.spoolMatch(null, spools, { uid: '0A0B0C0D' }), { action: 'none' });
});

test('VENDOR "Generic" is no maker: it neither blocks a branded spool nor names one', () => {
  const tray = R.rfidTray({ VERSION: 1, MAIN_TYPE: 'PLA', VENDOR: 'Generic', RGB_1: 526861 });
  assert.equal(tray.vendor, null);
  assert.deepEqual(R.spoolMatch(tray, [{ id: 'S1', material: 'PLA', color: '#080A0D', brand: 'Polymaker', weight: 500 }]),
    { action: 'link', spoolId: 'S1' }, 'a spool with a brand is not refused for a tag that names none');
});

test('a new spool from a tag keeps its uid; without one the prefill is as before', () => {
  const tray = R.rfidTray({ VERSION: 1, MAIN_TYPE: 'PETG', RGB_1: 0xFFFFFF, CARD_UID: [112, 175, 145, 226] });
  assert.deepEqual(R.spoolMatch(tray, []).prefill.tagUids, ['70AF91E2']);
  assert.ok(!('tagUids' in R.spoolMatch(R.rfidTray({ VERSION: 1, MAIN_TYPE: 'PETG', RGB_1: 0xFFFFFF }), []).prefill));
});

test('a used-up or resin spool is never matched by uid either', () => {
  const spools = [{ id: 'S1', material: 'PLA', weight: 0, tagUids: ['70AF91E2'] }, { id: 'R1', materialType: 'resin', tagUids: ['70AF91E2'] }];
  assert.deepEqual(R.spoolMatch(null, spools, { uid: '70AF91E2' }), { action: 'none' });
});
