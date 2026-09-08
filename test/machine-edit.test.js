/**
 * lib/machine-edit.js — what the shop floor's editor decides, lifted.
 *
 * A HONEST NOTE ON THE PROOF. The Electron machine editor mutates a draft
 * through thirty separate event handlers, so most of it is not a function that
 * can be copied and run beside a module. Two pieces are:
 *
 *  * `fillSpecs` — what picking a printer model fills in — is copied below
 *    VERBATIM (its four DOM writes answered by a fake form) and compared
 *    against `applySpecs` over every printer in the catalogue and every shape
 *    of machine it can be applied to. That is the piece where the decisions
 *    are, including the two rules the original carries in capitals.
 *  * The specs line is compared string for string.
 *
 * The rest — `newMachine` and `applyEdit` — is a NEW rule assembled from the
 * editor's scattered handlers, not a lift, and is tested on its behaviour. Said
 * plainly because a weaker guarantee described as a strong one is worse than a
 * weak one nobody relied on.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/nozzle-wear-data.js');
const KhaytNozzleWear = require('../lib/nozzle-wear.js');
const catalog = require('../lib/printer-catalog.js');
const M = require('../lib/machine-edit.js');

const ORIGINAL = `
function fillSpecsOn(draft, form, settings, t) {
  const modal = { querySelector: (sel) => form[sel] || null };
  const pmHint = form.pmHint;
        const fillSpecs = (s, name) => {
          draft.printerModel = s.printerModel || name;
          draft.printerModelName = name;
          if (s.vendor) draft.vendor = s.vendor;
          if (s.bed) draft.bed = s.bed;
          if (s.maxColors) draft.maxColors = s.maxColors;
          if (s.powerDraw != null) draft.powerDraw = s.powerDraw;
          const nameEl = modal.querySelector('#machName');
          if (nameEl && !nameEl.value.trim()) { nameEl.value = name; draft.name = name; }
          if (s.nozzleDiameter) { const el = modal.querySelector('#machNozzleDiameter'); if (el) el.value = s.nozzleDiameter; draft.nozzleDiameter = s.nozzleDiameter; }
          if (s.extruderType)  { const el = modal.querySelector('#machExtruderType');  if (el) el.value = s.extruderType;  draft.extruderType  = s.extruderType; }
          /* THE NOZZLE MATERIAL IS THE POINT OF THE CATALOG KNOWING IT.
           *
           * A Bambu X1C ships hardened steel and a Prusa MK4S ships brass — a
           * ten-fold difference in expected life — and without this line both
           * still landed on the brass default, so the whole printer-facts sweep
           * changed nothing a shop could see. Only when the catalog actually
           * checked it: an unswept printer must keep asking rather than inherit
           * a maintenance threshold nobody chose.
           */
          if (s.nozzle && s.nozzle.material) {
            draft.nozzle = Object.assign({ installedAt: '', gramsAtInstall: 0 }, draft.nozzle, { material: s.nozzle.material });
            const matEl = modal.querySelector('#machNozzleMaterial');
            if (matEl) matEl.value = s.nozzle.material;
            /* FILL AN EMPTY THRESHOLD. NEVER REWRITE ONE THAT IS SET.
             *
             * This used to overwrite any value that MATCHED A SUGGESTION, on the
             * theory that such a value must be untouched. It is not a safe
             * theory: a shop that deliberately typed 5,000 has typed the same
             * number brass suggests, and the old table's brass default of 2,000
             * is still sitting in stores from before that figure changed. The
             * app cannot tell a default from a decision, so it was guessing —
             * about a maintenance setting, silently, with no way for the shop to
             * know it had happened.
             *
             * (This was first written up as the cause of a real threshold change
             * on a shop's U1. It was not: the shop had typed that number itself.
             * The behaviour is still wrong and still worth removing, and the
             * incident that prompted the look was not evidence for it — recorded
             * here so the next reader does not inherit a false story.) */
            const thEl = modal.querySelector('#machNozzleGramsThreshold');
            if (thEl && !thEl.value) {
              const g = KhaytNozzleWear.defaultThresholdFor(s.nozzle.material, settings);
              thEl.value = g;
              draft.nozzle.gramsThreshold = g;
            }
          }
          // Carried so the machine card can offer the vendor's support page, and
          // so the checked specs are on the machine rather than only in a table.
          if (s.support) draft.support = s.support;
          for (const f of ['maxHotendC', 'maxBedC', 'chamber', 'maxChamberC', 'filamentMm', 'feed', 'toolheads']) {
            if (s[f] != null) draft[f] = s[f];
          }
          if (pmHint) {
            const bits = [];
            if (s.bed) bits.push(\`\${s.bed.x}×\${s.bed.y}×\${s.bed.z} mm\`);
            if (s.nozzleDiameter) bits.push(\`\${s.nozzleDiameter} mm\`);
            if (s.maxColors > 1) bits.push(\`\${s.maxColors}×\`);
            if (s.powerDraw != null) bits.push(\`~\${s.powerDraw} W\`);
            // The checked specs, so the shop can see what the catalog knows —
            // and, just as usefully, what it does not.
            if (s.nozzle && s.nozzle.material) bits.push(s.nozzle.material);
            if (s.maxHotendC) bits.push(\`\${s.maxHotendC}°C\`);
            if (s.chamber === 'active') bits.push(\`\${s.maxChamberC || '?'}°C \${t('mach.chamber') || 'chamber'}\`);
            if (s.filamentMm && s.filamentMm !== 1.75) bits.push(\`\${s.filamentMm} mm\`);
            pmHint.textContent = bits.join(' · ') || (t('mach.printer_model_hint') || '');
          }
        };

  fillSpecs(form.specs, form.name);
  return { draft, form };
}
return fillSpecsOn;`;

/** The original, with the four form fields it writes to made observable. */
function runOriginal(draft, specs, name, settings) {
  const form = {
    specs, name,
    '#machName': { value: draft.name || '' },
    '#machNozzleDiameter': { value: '' },
    '#machExtruderType': { value: '' },
    '#machNozzleMaterial': { value: '' },
    '#machNozzleGramsThreshold': { value: draft.nozzle && draft.nozzle.gramsThreshold ? String(draft.nozzle.gramsThreshold) : '' },
    pmHint: { textContent: '' },
  };
  const scope = { KhaytNozzleWear, settings, t: (k) => k };
  const fn = new Function(...Object.keys(scope), ORIGINAL)(...Object.values(scope));
  return fn(draft, form, settings, (k) => k);
}

function rng(seed) {
  let x = seed >>> 0 || 1;
  return () => { x ^= x << 13; x >>>= 0; x ^= x >>> 17; x ^= x << 5; x >>>= 0; return x / 4294967296; };
}
const pick = (r, list) => list[Math.floor(r() * list.length)];

test('applySpecs agrees with the original for every printer in the catalogue', () => {
  const r = rng(2468);
  const printers = catalog.list();
  assert.ok(printers.length > 10, 'the catalogue is empty — this test would prove nothing');
  let checked = 0;
  for (const entry of printers) {
    const specs = catalog.toMachineSpecs(entry);
    const name = catalog.displayName(entry);
    for (let i = 0; i < 6; i++) {
      // Every shape of machine the model can be picked on: blank, named,
      // already carrying a nozzle, already carrying a threshold somebody typed.
      const before = { id: 'M1', color: '#5b9cf0' };
      if (r() < 0.5) before.name = 'Bench ' + i;
      if (r() < 0.4) before.nozzle = { material: 'brass', installedAt: '2026-01-01', gramsAtInstall: 120 };
      if (r() < 0.4) {
        before.nozzle = Object.assign({ material: 'brass', installedAt: '', gramsAtInstall: 0 },
                                      before.nozzle, { gramsThreshold: pick(r, [2000, 5000, 50000]) });
      }
      if (r() < 0.3) before.vendor = 'Someone';
      const settings = pick(r, [{}, { nozzleWear: { life: { brass: 3000 } } }]);

      const theirs = runOriginal(JSON.parse(JSON.stringify(before)), specs, name, settings).draft;
      const mine = JSON.parse(JSON.stringify(before));
      M.applySpecs(mine, specs, name, { settings });
      assert.deepEqual(mine, theirs, `${name} on ${JSON.stringify(before)}`);
      checked++;
    }
  }
  assert.ok(checked > 100, 'the comparison must actually have run');
});

test('the specs line agrees with the original, for every printer', () => {
  for (const entry of catalog.list()) {
    const specs = catalog.toMachineSpecs(entry);
    const out = runOriginal({ id: 'M1' }, specs, catalog.displayName(entry), {});
    assert.equal(M.specsLine(specs, { chamber: 'mach.chamber' }), out.form.pmHint.textContent,
      catalog.displayName(entry));
  }
});

test('a threshold somebody typed is never rewritten by picking a model', () => {
  // The rule the original carries in capitals, asserted on its own so a
  // refactor cannot quietly lose it.
  const entry = catalog.list().find((p) => catalog.toMachineSpecs(p).nozzle?.material === 'hardened');
  assert.ok(entry, 'no hardened-nozzle printer in the catalogue to test with');
  const specs = catalog.toMachineSpecs(entry);
  const machine = { id: 'M1', nozzle: { material: 'brass', gramsThreshold: 5000, installedAt: '2026-01-01', gramsAtInstall: 90 } };
  M.applySpecs(machine, specs, 'x', { settings: {} });
  assert.equal(machine.nozzle.gramsThreshold, 5000, 'a deliberate 5,000 survives');
  assert.equal(machine.nozzle.material, 'hardened', 'but the material the catalogue checked lands');
  assert.equal(machine.nozzle.installedAt, '2026-01-01', 'and when it went in is untouched');

  const blank = { id: 'M2' };
  M.applySpecs(blank, specs, 'x', { settings: {} });
  assert.equal(blank.nozzle.gramsThreshold, KhaytNozzleWear.defaultThresholdFor('hardened', {}),
    'an empty one is filled from what that material is expected to last');
});

test('a new machine takes the next colour along', () => {
  assert.equal(M.newMachine({ name: 'A' }, { id: 'M1', count: 0 }).machine.color, M.COLORS[0]);
  assert.equal(M.newMachine({ name: 'B' }, { id: 'M2', count: 1 }).machine.color, M.COLORS[1]);
  // And wraps, rather than running off the end of the palette.
  assert.equal(M.newMachine({ name: 'C' }, { id: 'M3', count: M.COLORS.length }).machine.color, M.COLORS[0]);
  assert.deepEqual(M.newMachine({ name: '  ' }, { id: 'M4', count: 0 }), { refused: 'name' });
});

test('an edit changes only what it was given', () => {
  const machine = { id: 'M1', name: 'Bench', color: '#5b9cf0', powerDraw: 120,
                    printerModelName: 'Bambu Lab X1 Carbon', compatMaterials: ['PLA'] };
  M.applyEdit(machine, { name: ' Bench 2 ' }, {});
  assert.deepEqual(machine, { id: 'M1', name: 'Bench 2', color: '#5b9cf0', powerDraw: 120,
                              printerModelName: 'Bambu Lab X1 Carbon', compatMaterials: ['PLA'] });
  assert.deepEqual(M.applyEdit(machine, { name: '' }, {}), { refused: 'name' });
  assert.equal(machine.name, 'Bench 2', 'and a refused edit changes nothing');
});

test('a bed needs all three dimensions, or it is not a bed', () => {
  const machine = { id: 'M1', name: 'B', bed: { x: 256, y: 256, z: 256 } };
  M.applyEdit(machine, { bed: { x: 220, y: 220, z: 250 } }, {});
  assert.deepEqual(machine.bed, { x: 220, y: 220, z: 250 });
  M.applyEdit(machine, { bed: { x: 220, y: 220, z: 0 } }, {});
  assert.equal(machine.bed, undefined, 'half a build volume is not a build volume');
});

test('a nozzle is written as a block, and an empty threshold falls back to the material', () => {
  const machine = { id: 'M1', name: 'B' };
  M.applyEdit(machine, { nozzle: { material: 'hardened', installedAt: '2026-09-01', gramsAtInstall: '400' } },
              { settings: {} });
  assert.equal(machine.nozzle.material, 'hardened');
  assert.equal(machine.nozzle.gramsAtInstall, 400);
  assert.equal(machine.nozzle.gramsThreshold, KhaytNozzleWear.defaultThresholdFor('hardened', {}));
  M.applyEdit(machine, { nozzle: { material: 'brass', gramsThreshold: '7000' } }, { settings: {} });
  assert.equal(machine.nozzle.gramsThreshold, 7000, 'a figure the shop typed is kept');
  assert.equal(machine.nozzle.installedAt, '', 'and the block is whole — a half-written nozzle lies about wear');
});

// ── What kind of machine this is ───────────────────────────────────────────

require('../lib/machine-kinds.js');

test('a machine can be told it is a laser cutter', () => {
  const m = { id: 'M1', name: 'Ruida' };
  KhaytMachineEdit.applyEdit(m, { kind: 'laser' }, {});
  assert.equal(m.kind, 'laser');
});

test('a kind the vocabulary does not know is refused where it is WRITTEN', () => {
  // Not at every screen that reads it: a word nobody knows, once in the book,
  // reads back as FDM for ever and the shop's answer is silently lost.
  const m = { id: 'M1', name: 'Thing' };
  KhaytMachineEdit.applyEdit(m, { kind: 'waterjet' }, {});
  assert.equal(m.kind, 'fdm');
});

test('editing something else does not blank the kind', () => {
  const m = { id: 'M1', name: 'Ruida', kind: 'laser' };
  KhaytMachineEdit.applyEdit(m, { powerDraw: 80 }, {});
  assert.equal(m.kind, 'laser', 'a nozzle edit must not turn a laser into a printer');
});

test('a machine written before this field existed is left without one', () => {
  const m = { id: 'M1', name: 'Old' };
  KhaytMachineEdit.applyEdit(m, { name: 'Older' }, {});
  assert.equal('kind' in m, false, 'and the module reads that as FDM, which it is');
});
