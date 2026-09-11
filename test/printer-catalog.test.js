const { test } = require('node:test');
const assert = require('node:assert/strict');
const cat = require('../lib/printer-catalog.js');

test('list() returns entries with computed names, sorted, non-empty', () => {
  const all = cat.list();
  assert.ok(all.length >= 40, 'has a real catalog');
  assert.ok(all.every(p => p.id && p.name && p.bed), 'each entry has id/name/bed');
  // sorted by vendor then model
  for (let i = 1; i < all.length; i++) {
    const a = all[i - 1], b = all[i];
    assert.ok(a.vendor.localeCompare(b.vendor) < 0 || (a.vendor === b.vendor && a.model.localeCompare(b.model) <= 0), 'sorted');
  }
});

test('get() resolves by id and adds a display name', () => {
  const p = cat.get('bambu-x1c');
  assert.equal(p.name, 'Bambu Lab X1 Carbon');
  assert.equal(p.maxColors, 4);
  assert.equal(p.powerW, 120);
  assert.equal(cat.get('nope'), null);
});

test('search() is token-based across vendor/model/name', () => {
  assert.ok(cat.search('bambu x1').some(p => p.id === 'bambu-x1c'), 'multi-token matches');
  assert.ok(cat.search('ender 3').length >= 1);
  assert.ok(cat.search('prusa').every(p => p.vendor === 'Prusa'));
  assert.equal(cat.search('').length, cat.list().length, 'empty query → full list');
  assert.equal(cat.search('zzzznope').length, 0);
});

test('toMachineSpecs() maps to Khayt machine fields incl. power draw', () => {
  const s = cat.toMachineSpecs('prusa-mk4s');
  assert.equal(s.printerModel, 'prusa-mk4s');
  assert.equal(s.printerName, 'Prusa MK4S');
  assert.equal(s.nozzleDiameter, 0.4);
  // ONE, not five. An MK4S is a single-extruder printer; five is what it
  // reaches with an MMU3, and this used to seed the ceiling onto a machine the
  // shop had just said it owns. See the block at the end of this file.
  assert.equal(s.maxColors, 1);
  assert.equal(s.colorCeiling, 5);
  assert.equal(s.extruderType, 'Direct Drive');
  assert.equal(s.powerDraw, 90);
  assert.deepEqual(s.bed, { x: 250, y: 210, z: 220 });
  // accepts an entry object too
  const s2 = cat.toMachineSpecs(cat.get('bambu-a1-mini'));
  assert.equal(s2.powerDraw, 55);
  assert.equal(cat.toMachineSpecs('nope').printerModel, undefined);
});

test('ids are unique', () => {
  const ids = cat.PRINTERS.map(p => p.id);
  assert.equal(new Set(ids).size, ids.length, 'no duplicate ids');
});

// ── WHAT A MACHINE IS, AGAINST WHAT IT COULD BECOME ─────────────────────────
//
// `maxColors` held the CEILING and `toMachineSpecs` seeded a machine from it,
// so adding a bare Prusa CORE One gave Khayt a machine it believed could print
// five colours — true of one with an MMU3 bolted on, false of the one on the
// bench. Every capacity and colour check downstream believed it, and the same
// was true of every Bambu without an AMS and every MK4 without an MMU.

test('a machine is seeded with what it prints as sold, not its ceiling', () => {
  const core = cat.toMachineSpecs(cat.get('prusa-core-one'));
  assert.equal(core.maxColors, 1, 'a bare CORE One is a one-colour printer');
  assert.equal(core.colorCeiling, 5, 'the ceiling is still worth knowing');
  assert.equal(core.colorAddOn, 'MMU3', 'and what it takes to reach it');

  // Not a Prusa quirk — the same shape everywhere an accessory is involved.
  assert.equal(cat.toMachineSpecs(cat.get('bambu-p1p')).maxColors, 1);
  assert.equal(cat.toMachineSpecs(cat.get('prusa-mk4s')).maxColors, 1);
  assert.equal(cat.toMachineSpecs(cat.get('creality-k2-plus')).maxColors, 1);
});

/// Built-in multi-material is NOT an upgrade and must not be demoted: the U1's
/// toolchanger, the J1's IDEX and the dual-extruder machines come that way.
test('a machine whose multi-material is built in keeps its colours', () => {
  for (const [id, colours] of [['snapmaker-u1', 4], ['snapmaker-j1', 2],
                               ['ultimaker-s5', 2], ['raise3d-pro3', 2]]) {
    const specs = cat.toMachineSpecs(cat.get(id));
    assert.equal(specs.maxColors, colours, `${id} lost colours it has`);
    assert.equal(specs.colorAddOn, null, `${id} claims an add-on it does not need`);
  }
});

/// A machine with two nozzles prints two materials with no accessory at all,
/// and reaches four with one.
test('a dual-nozzle machine is seeded at two, not one and not four', () => {
  const h2d = cat.toMachineSpecs(cat.get('bambu-h2d'));
  assert.equal(h2d.maxColors, 2);
  assert.equal(h2d.colorCeiling, 4);
});

/// The two fields have to agree with each other, whatever is added later.
test('every entry that needs an accessory names it, and only those', () => {
  for (const p of cat.PRINTERS) {
    const stock = cat.stockColorsOf(p);
    const ceiling = p.maxColors || 1;
    assert.ok(stock >= 1, `${p.id} prints fewer than one colour`);
    assert.ok(stock <= ceiling, `${p.id} is sold with more colours than its ceiling`);
    if (stock < ceiling) {
      assert.ok(p.colorAddOn, `${p.id} needs an accessory and does not say which`);
    } else {
      assert.ok(!p.colorAddOn, `${p.id} names an accessory it does not need`);
    }
  }
});

/// A bare machine is not a multi-material machine, whatever mechanism it would
/// use if it were equipped. Only checked where the facts file says nothing:
/// `feed` there is SOURCED and describes the mechanism, not a count.
test('feed falls back to single for a machine sold with one colour', () => {
  const bare = { id: 'x', vendor: 'V', model: 'M', maxColors: 4, stockColors: 1,
                 colorAddOn: 'AMS', bed: { x: 1, y: 1, z: 1 }, nozzle: 0.4, tech: 'fdm' };
  assert.equal(cat.toMachineSpecs(bare).feed, 'single');
  assert.equal(cat.toMachineSpecs({ ...bare, stockColors: 3 }).feed, 'multi');
});
