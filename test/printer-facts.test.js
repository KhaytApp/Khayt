/**
 * The printer catalog's checked facts, and the two things it used to get wrong.
 *
 * `extruder` had exactly two values, 'direct' and 'bowden'. A toolchanger is
 * neither, so the Snapmaker U1 — four toolheads, five-second swaps — was
 * recorded as "direct", and so was the Prusa XL with up to five independent
 * toolheads. The field read as an answer and was not one.
 *
 * There was no nozzle material at all, which is the single field the wear model
 * most needs: a Bambu X1C ships hardened steel and a Prusa MK4S ships brass, a
 * ten-fold difference in expected life, and both were handed the same default.
 *
 * Everything asserted here is a DEFAULT. The machine editor writes these into a
 * form the shop can overwrite; nothing in the catalog constrains a machine.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const FACTS = require('../lib/printer-facts.js');
const CATALOG = require('../lib/printer-catalog.js');

test('a toolchanger is recorded as a toolchanger', () => {
  for (const [id, heads] of [['snapmaker-u1', 4], ['prusa-xl', 5]]) {
    const p = CATALOG.get(id);
    assert.equal(p.feed, 'toolchanger', `${id} is a toolchanger`);
    assert.equal(p.toolheads, heads, `${id} has ${heads} toolheads`);
    // And it is STILL direct drive. The first attempt at this wrote
    // 'toolchanger' into `extruder`, which threw the drive type away and broke
    // a test that was right to complain — two questions, two fields.
    assert.equal(p.extruder, 'direct', `${id} toolheads are direct drive`);
  }
});

test('a multi-material unit is not the same thing as a toolchanger', () => {
  // Both give a shop more colours and they wear nozzles completely differently:
  // four toolheads spread the wear across four nozzles, an AMS puts every colour
  // through one. Collapsing them would make the wear model wrong for whichever
  // it guessed against.
  assert.equal(CATALOG.get('bambu-x1c').feed, 'multi');
  assert.equal(CATALOG.get('snapmaker-u1').feed, 'toolchanger');
  assert.equal(CATALOG.get('snapmaker-j1').feed, 'idex');
  assert.equal(CATALOG.get('bambu-h2d').feed, 'dual');
});

test('every drive and feed kind in use has a human label', () => {
  for (const p of CATALOG.list()) {
    assert.ok(FACTS.EXTRUDER_KINDS[p.extruder], `drive '${p.extruder}' (${p.id}) has no label`);
    if (p.feed) assert.ok(FACTS.FEED_KINDS[p.feed], `feed '${p.feed}' (${p.id}) has no label`);
  }
  for (const id of ['snapmaker-u1', 'bambu-h2d', 'snapmaker-j1']) {
    const s = CATALOG.toMachineSpecs(id);
    assert.ok(s.extruderType, `${id} must not auto-fill a blank drive type`);
    assert.ok(s.feedLabel, `${id} must not auto-fill a blank feed type`);
  }
});

test('nozzle material is filled in only where it was looked up', () => {
  // Present and sourced.
  for (const [id, material] of [
    ['bambu-x1c', 'hardened'], ['bambu-p1s', 'stainless'], ['bambu-a1', 'stainless'],
    ['prusa-mk4s', 'brass'], ['prusa-xl', 'brass'],
    ['snapmaker-u1', 'stainless'], ['creality-k2-plus', 'hardened'],
  ]) {
    assert.equal(CATALOG.get(id).nozzleMaterial, material, `${id} nozzle material`);
    assert.ok(CATALOG.get(id).source, `${id} must name where that came from`);
    assert.deepEqual(CATALOG.toMachineSpecs(id).nozzle, { material },
      `${id} should auto-fill the nozzle material so the wear threshold matches what is fitted`);
  }
  // Absent where it was not. Guessing would silently set a maintenance
  // threshold nobody chose, which is worse than asking.
  const unknown = CATALOG.get('creality-ender3');
  assert.equal(unknown.nozzleMaterial, undefined);
  assert.equal(CATALOG.toMachineSpecs('creality-ender3').nozzle, undefined);
});

test('the nozzle materials use the same keys as the wear model', () => {
  // Two vocabularies that drift apart would leave a printer auto-filling a
  // material the wear table has no row for, silently falling back to 'other'.
  const wear = require('../lib/nozzle-wear-data.js');
  for (const p of CATALOG.list()) {
    if (!p.nozzleMaterial) continue;
    assert.ok(wear.NOZZLE_LIFE_G[p.nozzleMaterial],
      `${p.id} claims nozzle material '${p.nozzleMaterial}', which lib/nozzle-wear-data.js does not know`);
  }
});

test('every printer offers somewhere to get help', () => {
  const without = CATALOG.list().filter((p) => !p.support && p.vendor !== 'Generic');
  assert.deepEqual(without.map((p) => p.name), [],
    'these printers have no support link, and a shop with a broken machine has nowhere to go');
});

test('support links are absolute https, because they open in a browser', () => {
  for (const url of [...Object.values(FACTS.VENDOR_SUPPORT), ...Object.values(FACTS.MODEL_SUPPORT)]) {
    assert.match(url, /^https:\/\/[a-z0-9.-]+\//i, `${url} is not an absolute https URL`);
  }
});

test('every sourced fact names a real source, with what was measured', () => {
  assert.match(FACTS.CHECKED_ON, /^\d{4}-\d{2}-\d{2}$/);
  for (const [key, src] of Object.entries(FACTS.SOURCES)) {
    assert.match(src.url, /^https:\/\//, `${key} needs a URL`);
    assert.ok(src.name, `${key} needs a name`);
    assert.ok(src.what && src.what.length > 40,
      `${key} must say WHAT it establishes — a bare link is not a citation`);
  }
  for (const [id, f] of Object.entries(FACTS.FACTS)) {
    if (f.nozzleMaterial) {
      assert.ok(f.src, `${id} claims a nozzle material and must cite it`);
      assert.ok(FACTS.SOURCES[f.src], `${id} cites '${f.src}', which is not in SOURCES`);
    }
  }
});

test('the facts layer never invents a printer the catalog does not have', () => {
  const ids = new Set(CATALOG.PRINTERS.map((p) => p.id));
  for (const id of Object.keys(FACTS.FACTS)) {
    assert.ok(ids.has(id), `facts exist for '${id}', which is not in the catalog`);
  }
  for (const id of Object.keys(FACTS.MODEL_SUPPORT)) {
    assert.ok(ids.has(id), `a support link exists for '${id}', which is not in the catalog`);
  }
});

test('the spec sweep records temperatures, and they are physically sane', () => {
  // Collected vendor page by vendor page rather than from memory, which is what
  // produced the nozzle-wear numbers that had to be thrown away. A figure here
  // without a source is a figure nobody checked.
  const swept = CATALOG.list().filter((p) => p.maxHotendC || p.maxBedC);
  assert.ok(swept.length >= 12, `expected the sweep to cover a dozen printers, got ${swept.length}`);
  for (const p of swept) {
    assert.ok(p.source, `${p.id} carries specs and must cite them`);
    // Each field is checked ONLY IF PRESENT. A printer whose spec page gave a
    // hotend temperature but no bed temperature is partially swept, which is an
    // honest state — demanding the pair would push whoever fills this in next
    // towards inventing the missing half, which is the whole failure this file
    // exists to avoid.
    if (p.maxHotendC != null) {
      assert.ok(p.maxHotendC >= 200 && p.maxHotendC <= 500, `${p.id} hotend ${p.maxHotendC}°C is not plausible`);
    }
    if (p.maxBedC != null) {
      assert.ok(p.maxBedC >= 50 && p.maxBedC <= 200, `${p.id} bed ${p.maxBedC}°C is not plausible`);
    }
    if (p.maxSpeedMms != null) {
      assert.ok(p.maxSpeedMms >= 50 && p.maxSpeedMms <= 1500, `${p.id} speed ${p.maxSpeedMms} mm/s is not plausible`);
    }
    if (p.chamber === 'active') {
      assert.ok(p.maxChamberC > 0, `${p.id} has an actively heated chamber and should say how hot`);
    }
    if (p.filamentMm) assert.ok([1.75, 2.85, 3].includes(p.filamentMm), `${p.id} filament ${p.filamentMm}mm`);
  }
});

test('a machine picked from the catalog inherits the specs as editable defaults', () => {
  // The whole point: the catalog fills the form, it does not lock it.
  const s = CATALOG.toMachineSpecs('bambu-x1c');
  assert.equal(s.maxHotendC, 300);
  assert.equal(s.maxBedC, 100);
  assert.equal(s.chamber, 'passive');
  assert.deepEqual(s.nozzle, { material: 'hardened' });
  assert.ok(s.support);
});

test('an unswept printer offers nothing rather than something invented', () => {
  const s = CATALOG.toMachineSpecs('creality-ender3');
  for (const field of ['maxHotendC', 'maxBedC', 'chamber', 'nozzle']) {
    assert.ok(s[field] == null, `${field} should be absent until someone checks a spec sheet`);
  }
  // But the support link still works, because that one IS checked for everybody.
  assert.ok(s.support);
});

test('2.85 mm machines are recorded as such, because 1.75 spools will not feed them', () => {
  // The single most expensive spec to get wrong: a shop buys the wrong filament
  // for its UltiMaker and finds out at the extruder.
  for (const id of ['ultimaker-s5', 'ultimaker-s3']) {
    assert.equal(CATALOG.get(id).filamentMm, 2.85, `${id} takes 2.85 mm filament`);
  }
  // And nothing else in the catalog claims 2.85 without having been checked.
  for (const p of CATALOG.list()) {
    if (p.filamentMm === 2.85) assert.ok(p.source, `${p.id} claims 2.85 mm and must cite it`);
  }
});

test('Voron is left unswept on purpose, and says why', () => {
  // Self-sourced kits: the hotend, bed and extruder are whatever the builder
  // fitted. A spec row here would describe a machine nobody owns.
  for (const p of CATALOG.list().filter((x) => x.vendor === 'Voron')) {
    assert.equal(p.maxHotendC, undefined, `${p.id} should carry no hotend spec`);
    assert.ok(p.support, 'a Voron still needs its build documentation');
  }
});

test('resin printers are described as resin printers', () => {
  // They used to carry `extruder: 'direct'` and `nozzle: 0`, which is not a
  // missing spec but a WRONG one — it says an MSLA machine has a nozzle whose
  // diameter happens to be zero. What decides what these can make is the screen
  // and the XY pixel size.
  const swept = CATALOG.list().filter((p) => p.tech === 'resin' && p.xyMicrons);
  assert.ok(swept.length >= 4, `expected the resin sweep to cover four machines, got ${swept.length}`);
  for (const p of swept) {
    assert.ok(p.source, `${p.id} carries resin specs and must cite them`);
    assert.ok(p.xyMicrons >= 5 && p.xyMicrons <= 100, `${p.id} XY ${p.xyMicrons}µm is not plausible`);
    assert.ok(p.lcdInch > 0 && p.lcdInch < 20, `${p.id} LCD ${p.lcdInch}" is not plausible`);
    // And they must NOT have acquired FDM specs along the way.
    assert.equal(p.maxHotendC, undefined, `${p.id} is a resin printer and has no hotend`);
    assert.equal(p.maxBedC, undefined, `${p.id} is a resin printer and has no heated bed in the FDM sense`);
  }
});

test('no FDM printer has picked up resin fields, or the reverse', () => {
  for (const p of CATALOG.list()) {
    if (p.tech === 'fdm') {
      assert.equal(p.xyMicrons, undefined, `${p.id} is FDM and should not carry an LCD pixel size`);
      assert.equal(p.lcdInch, undefined, `${p.id} is FDM and should not carry an LCD`);
    }
  }
});

test('no printer is listed twice in FACTS', () => {
  // A duplicate key in an object literal is SILENT: the last one wins, nothing
  // throws, and the loss is invisible from the parsed object because it has
  // already collapsed. It happened here — a leftover `{ enclosed: true }` stub
  // sat below the fully sourced K1 and K1 Max entries and quietly erased their
  // temperatures, speeds and citation. The sweep reported them as unswept and
  // the reason was ten lines further down the same file.
  //
  // So this reads the SOURCE, not the object, because the object cannot show it.
  const src = fs.readFileSync(path.join(__dirname, '..', 'lib', 'printer-facts.js'), 'utf8');
  const body = src.slice(src.indexOf('const FACTS = {'), src.indexOf('\n  };', src.indexOf('const FACTS = {')));
  const keys = [...body.matchAll(/^\s{4}'([a-z0-9-]+)':/gm)].map((m) => m[1]);
  const seen = new Set();
  const dupes = keys.filter((k) => (seen.has(k) ? true : (seen.add(k), false)));
  assert.deepEqual([...new Set(dupes)], [], 'these ids appear more than once and the later entry silently wins');
  assert.ok(keys.length > 30, `expected the sweep to cover most of the catalog, parsed ${keys.length} entries`);
});

test('picking a printer model applies its nozzle material', () => {
  // Without this the entire printer-facts sweep changed nothing a shop could
  // see: an X1C (hardened, ~50 kg) and an MK4S (brass, ~5 kg) both landed on
  // the brass default, and the wear warning fired at the wrong time for one of
  // them.
  // The rule moved into lib/machine-edit.js, so this RUNS it rather than
  // reading the renderer's source: a hardened-nozzle printer and a brass one
  // must land on their own materials and their own expected lives.
  require('../lib/nozzle-wear-data.js');
  const wear = require('../lib/nozzle-wear.js');
  const catalog = require('../lib/printer-catalog.js');
  const { applySpecs } = require('../lib/machine-edit.js');
  const byMaterial = {};
  for (const entry of catalog.list()) {
    const material = catalog.toMachineSpecs(entry).nozzle?.material;
    if (material && !byMaterial[material]) byMaterial[material] = entry;
  }
  assert.ok(byMaterial.hardened && byMaterial.brass,
    'the catalogue must know at least one hardened and one brass printer for this to prove anything');
  for (const [material, entry] of Object.entries(byMaterial)) {
    const machine = { id: 'M1' };
    applySpecs(machine, catalog.toMachineSpecs(entry), catalog.displayName(entry), { settings: {} });
    assert.equal(machine.nozzle.material, material, catalog.displayName(entry));
    assert.equal(machine.nozzle.gramsThreshold, wear.defaultThresholdFor(material, {}),
      `${catalog.displayName(entry)}: the threshold must move with the material`);
  }
  // But only when the catalog actually checked. An unswept printer keeps asking.
  const unswept = { id: 'M2' };
  applySpecs(unswept, { printerModel: 'x', bed: { x: 1, y: 1, z: 1 } }, 'Unknown', { settings: {} });
  assert.equal(unswept.nozzle, undefined,
    'an unknown fitment must not be defaulted to brass — the catalog omits it on purpose');
  // And the renderer still puts it in the field the shop can see and change.
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'machines.js'), 'utf8');
  const fill = src.slice(src.indexOf('const fillSpecs = '), src.indexOf('// Network scan'));
  assert.match(fill, /MachineEdit\.applySpecs\(/, 'fillSpecs must apply the shared rule');
  assert.match(fill, /machNozzleMaterial/, 'and put the material in the field the shop can see and change');
});

test('a threshold the shop set is never rewritten', () => {
  /* The app cannot tell a default from a decision, and it used to guess.
   *
   * Picking a printer model, or changing the nozzle-material dropdown,
   * overwrote any threshold that MATCHED A SUGGESTION — on the theory that such
   * a value must be untouched. A shop that deliberately typed 5,000 has typed
   * the same number brass suggests, and the old table's brass default of 2,000
   * is still sitting in stores from before that figure changed. The app cannot
   * tell a default from a decision, so it was guessing about a maintenance
   * setting, silently.
   *
   * No incident is claimed here. A threshold change on a real machine prompted
   * the look and turned out to be the shop typing its own number; the guessing
   * is wrong on its own terms and that is the whole reason this holds.
   */
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'machines.js'), 'utf8');
  // No path may decide a stored value is "really" a default and replace it.
  assert.doesNotMatch(src, /suggestions\.includes\(\+\w*[Ff]ield\.value\)/,
    'a stored threshold must not be overwritten because it happens to equal a suggestion');
  assert.doesNotMatch(src, /\+field\.value === KhaytNozzleWear\.defaultThresholdFor\(previous/,
    'nor because it equals the PREVIOUS material\'s suggestion');
  // Filling an empty one is fine, and is the only thing allowed.
  assert.match(src, /if \(thEl && !thEl\.value\)/, 'an empty threshold may still be filled in');
  // And the rule itself only fills an empty one.
  require('../lib/nozzle-wear-data.js');
  require('../lib/nozzle-wear.js');
  const cat = require('../lib/printer-catalog.js');
  const { applySpecs: apply } = require('../lib/machine-edit.js');
  const hardened = cat.list().find((p) => cat.toMachineSpecs(p).nozzle?.material === 'hardened');
  const kept = { id: 'M1', nozzle: { material: 'brass', gramsThreshold: 5000, installedAt: '2026-01-01', gramsAtInstall: 90 } };
  apply(kept, cat.toMachineSpecs(hardened), 'x', { settings: {} });
  assert.equal(kept.nozzle.gramsThreshold, 5000,
    'a threshold the shop typed must survive picking a model');
  assert.match(src, /if \(field && !field\.value\)/, 'and so may an empty one in the log-nozzle dialog');
});
