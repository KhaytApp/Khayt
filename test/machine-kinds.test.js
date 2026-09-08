'use strict';

const test = require('node:test');
const assert = require('node:assert');
const MK = require('../lib/machine-kinds.js');

// ── Absent is FDM, and it is not a guess ───────────────────────────────────

test('a machine with no kind is a filament printer, because every old one is', () => {
  // Until this module existed nothing else could be recorded, so reading a
  // kindless machine as FDM is correct rather than convenient.
  assert.equal(MK.kindOf({}), 'fdm');
  assert.equal(MK.kindOf(null), 'fdm');
  assert.equal(MK.kindOf({ kind: '' }), 'fdm');
  assert.equal(MK.kindOf({ kind: '   ' }), 'fdm');
});

test('a kind this Khayt has not learned is drawn as FDM rather than not drawn', () => {
  // A newer Khayt writing `kind: "waterjet"` into a synced book must not make a
  // machine vanish from an older one. Wrong is survivable; missing is not.
  assert.equal(MK.kindOf({ kind: 'waterjet' }), 'fdm');
});

test('the kind is read case- and space-insensitively', () => {
  assert.equal(MK.kindOf({ kind: 'LASER' }), 'laser');
  assert.equal(MK.kindOf({ kind: ' Resin ' }), 'resin');
});

// ── What each kind is ──────────────────────────────────────────────────────

test('every kind says what it consumes and in what unit', () => {
  assert.deepEqual(MK.consumable('fdm'), { name: 'filament', unit: 'g' });
  assert.deepEqual(MK.consumable('resin'), { name: 'resin', unit: 'ml' });
  assert.deepEqual(MK.consumable('uv'), { name: 'ink', unit: 'ml' });
  assert.deepEqual(MK.consumable('laser'), { name: 'sheet', unit: 'sheet' });
  assert.deepEqual(MK.consumable('cnc'), { name: 'stock', unit: 'sheet' });
});

test('a resin printer has TWO things that wear, on two different clocks', () => {
  // The film is counted in prints and the screen in hours lit. A shop watching
  // only one gets a ruined print from whichever it was not watching.
  const wear = MK.wearParts('resin');
  assert.equal(wear.length, 2);
  assert.deepEqual(wear.map(w => w.part), ['fep', 'lcd']);
  assert.deepEqual(wear.map(w => w.unit), ['prints', 'h']);
});

test('a nozzle wears in grams, which is what abrasive filament actually costs it', () => {
  assert.deepEqual(MK.wearParts('fdm'), [{ part: 'nozzle', unit: 'g' }]);
});

test('nothing but a filament printer has a nozzle', () => {
  for (const kind of MK.KINDS.filter(k => k !== 'fdm')) {
    assert.ok(!MK.wearParts(kind).some(w => w.part === 'nozzle'),
      `${kind} was given a nozzle`);
  }
});

test('the wear list is a copy, so a caller cannot edit the vocabulary', () => {
  const first = MK.wearParts('fdm');
  first.push({ part: 'nonsense', unit: 'g' });
  assert.equal(MK.wearParts('fdm').length, 1);
});

// ── Can Khayt ask it anything ──────────────────────────────────────────────

test('only a filament printer can be polled today, and the module says so plainly', () => {
  // Every protocol in this repo talks to an FDM printer. Claiming otherwise
  // would make a laser cutter look like a printer that is failing to answer,
  // and those two look identical to a status panel while meaning opposite
  // things.
  assert.equal(MK.isPolled('fdm'), true);
  for (const kind of ['resin', 'uv', 'laser', 'cnc']) {
    assert.equal(MK.isPolled(kind), false, `${kind} claims a protocol Khayt has not got`);
  }
});

test('a flatbed and a laser do not work in layers', () => {
  assert.equal(MK.isLayered('fdm'), true);
  assert.equal(MK.isLayered('resin'), true, 'resin is layered, it is just not filament');
  assert.equal(MK.isLayered('uv'), false);
  assert.equal(MK.isLayered('laser'), false);
  assert.equal(MK.isLayered('cnc'), false);
});

// ── What a screen may show ─────────────────────────────────────────────────

test('the FDM-only specs are offered to nothing else', () => {
  for (const field of ['nozzleDiameter', 'extruderType', 'maxColors']) {
    assert.ok(MK.showsSpec('fdm', field), `fdm should show ${field}`);
    for (const kind of ['resin', 'uv', 'laser', 'cnc']) {
      assert.ok(!MK.showsSpec(kind, field),
        `${kind} would show ${field} — the app told a laser its nozzle was 0.4 mm`);
    }
  }
});

test('every kind has a bed and draws power, because every kind has a size and a bill', () => {
  for (const kind of MK.KINDS) {
    assert.ok(MK.showsSpec(kind, 'bed'), kind);
    assert.ok(MK.showsSpec(kind, 'powerDraw'), kind);
  }
});

// ── The words ──────────────────────────────────────────────────────────────

test('the locale keys are built here, so no screen assembles one by hand', () => {
  const k = MK.keysFor('resin');
  assert.equal(k.name, 'mach.kind_resin');
  assert.equal(k.consumable, 'mach.consumes_resin');
  assert.equal(k.unit, 'unit.ml');
  assert.deepEqual(k.wear.map(w => w.label), ['mach.wear_fep', 'mach.wear_lcd']);
  assert.deepEqual(k.wear.map(w => w.unit), ['unit.prints', 'unit.h']);
});

test('an unknown kind gets FDM keys rather than a key naming the unknown kind', () => {
  assert.equal(MK.keysFor('waterjet').name, 'mach.kind_fdm');
});

// ── The vocabulary is closed ───────────────────────────────────────────────

test('spec() never returns null, whatever it is handed', () => {
  for (const bad of [null, undefined, '', 'nope', 42, {}]) {
    assert.ok(MK.spec(bad), String(bad));
    assert.ok(Array.isArray(MK.spec(bad).wear));
  }
});

test('every kind in the list has a full record', () => {
  for (const kind of MK.KINDS) {
    const s = MK.spec(kind);
    assert.ok(s.consumable && s.unit, kind);
    assert.ok(Array.isArray(s.wear) && s.wear.length > 0, `${kind} has nothing that wears out`);
    assert.ok(Array.isArray(s.specs) && s.specs.length > 0, kind);
    assert.equal(typeof s.polled, 'boolean', kind);
    assert.equal(typeof s.layered, 'boolean', kind);
  }
});
