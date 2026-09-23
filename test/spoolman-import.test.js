/**
 * `lib/spoolman-import.js` — a shop's Spoolman spools, onto Khayt's shelf.
 *
 * The fixture follows Spoolman's own models (`spoolman/api/v1/models.py` in
 * Donkie/Spoolman: `Spool`, `Filament`, `Vendor`) field for field, including
 * the ones that are nullable there, because an importer tested only against a
 * complete record is an importer that throws on the first shop's real one.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const I = require('../lib/spoolman-import.js');

const vendor = { id: 1, registered: '2025-01-02T10:00:00Z', name: 'Sunlu', comment: null,
  empty_spool_weight: 140, external_id: null, extra: {} };
const filament = (over) => ({
  id: 7, registered: '2025-01-02T10:00:00Z', name: 'Galaxy Black', vendor, material: 'PETG',
  price: 85, density: 1.27, diameter: 1.75, weight: 1000, spool_weight: 140,
  article_number: null, comment: null, settings_extruder_temp: 240, settings_bed_temp: 70,
  color_hex: '1b1b1f', multi_color_hexes: null, multi_color_direction: null,
  external_id: null, extra: {}, tags: [], ...over,
});
const spool = (over) => ({
  id: 12, registered: '2025-03-04T08:30:00Z', first_used: '2025-03-10T09:00:00Z',
  last_used: '2025-06-01T12:00:00Z', filament: filament(), price: 79,
  remaining_weight: 612.4, initial_weight: 1000, spool_weight: 140, used_weight: 387.6,
  remaining_length: 200000, used_length: 125000, location: 'Dry box 2', lot_nr: 'L-2231',
  comment: null, archived: false, extra: {}, tags: [], ...over,
});
const ctx = () => { let n = 0; return { today: '2026-09-23', mintId: () => `SP-${++n}` }; };

test('a full Spoolman spool becomes a Khayt spool, field for field', () => {
  assert.deepEqual(I.toSpool(spool(), { id: 'SP-1', today: '2026-09-23' }), {
    id: 'SP-1', material: 'Sunlu PETG', colourVariant: 'Galaxy Black', cost: 79,
    weight: 612.4, spoolWeight: 1000, color: '#1B1B1F', materialType: 'fdm',
    purchasedAt: '2025-03-04', spoolmanId: 12, lot: 'L-2231', storage: 'Dry box 2', openedAt: '2025-03-10',
  });
});

test('what Spoolman leaves null is filled from the filament, or left out', () => {
  const s = I.toSpool(spool({
    price: null, remaining_weight: null, initial_weight: null, used_weight: 250,
    location: null, lot_nr: null, first_used: null,
    filament: filament({ vendor: null, name: null, color_hex: null, multi_color_hexes: 'ff0000,00ff00' }),
  }), { id: 'X', today: '2026-09-23' });
  assert.equal(s.material, 'PETG', 'no vendor: the material alone');
  assert.equal(s.cost, 85, 'the filament price when the spool has none');
  assert.equal(s.spoolWeight, 1000, "the filament's net weight when the spool has none");
  assert.equal(s.weight, 750, 'what is left, worked out from what was used');
  assert.equal(s.color, '#FF0000', 'a multi-colour spool takes its first colour');
  for (const k of ['lot', 'storage', 'openedAt', 'colourVariant']) assert.equal(k in s, false, `${k} written empty`);
});

test('a spool with nothing to match a job by is not brought across', () => {
  assert.equal(I.toSpool(spool({ filament: filament({ vendor: null, material: null, name: null }) }),
    { id: 'X', today: '2026-09-23' }), null);
});

test('an import run twice is one import', () => {
  const smSpools = [spool({ id: 1 }), spool({ id: 2 }), spool({ id: 3, archived: true })];
  const first = I.plan(smSpools, [], ctx());
  assert.equal(first.add.length, 2);
  assert.deepEqual(first.skipped, { archived: 1, already: 0, unnamed: 0 });
  assert.deepEqual(first.add.map((s) => s.id), ['SP-1', 'SP-2'], 'ids are minted in order, once each');
  // The shelf now holds them, and Khayt has since used some of the first.
  const shelf = first.add.map((s) => ({ ...s }));
  shelf[0].weight = 100;
  const again = I.plan([...smSpools, spool({ id: 4 })], shelf, ctx());
  assert.deepEqual(again.add.map((s) => s.spoolmanId), [4], 'only the new roll comes across');
  assert.equal(again.skipped.already, 2);
  assert.equal(shelf[0].weight, 100, "a second import put back grams Khayt had counted as used");
});

test('the same Spoolman spool listed twice in one import is added once', () => {
  const out = I.plan([spool({ id: 9 }), spool({ id: 9 })], [], ctx());
  assert.equal(out.add.length, 1);
  assert.equal(out.skipped.already, 1);
});

test('rubbish in the list is counted, not thrown on', () => {
  const out = I.plan([null, {}, spool({ id: 5 })], null, ctx());
  assert.equal(out.add.length, 1);
  assert.equal(out.skipped.unnamed, 2);
  assert.deepEqual(I.plan(undefined, [], ctx()), { add: [], skipped: { archived: 0, already: 0, unnamed: 0 } });
});

test('the page asked for is Spoolman\'s own endpoint, without archived spools', () => {
  assert.equal(I.listPath(0, 500), '/api/v1/spool?allow_archived=false&limit=500&offset=0');
  assert.equal(I.DEFAULT_PORT, 7912);
});

test('it loads without require, as JavaScriptCore loads it', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const vm = require('node:vm');
  const c = {};
  vm.createContext(c);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'lib', 'spoolman-import.js'), 'utf8'), c);
  assert.equal(vm.runInContext('KhaytSpoolmanImport.colourOf({ color_hex: "abcdef" })', c), '#ABCDEF');
});
