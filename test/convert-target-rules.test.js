/**
 * The converter's target gates, shared now.
 *
 * Which printers a file may be retargeted to, which ones save a Generic 3MF
 * instead, and when Full Spectrum and band-swap are offered used to live in
 * renderer/converter.js, so the native Mac had nothing to ask. They are in
 * lib/printer-profiles.js, and the members-in halves of `analyze`,
 * `fsPreview` and `analyzeColorBands` in lib/mf-convert.js let a host with its
 * own zip (the Mac) ask the same questions of the same rules.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const P = require('../lib/printer-profiles.js');
const MF = require('../lib/mf-convert.js');
const Z = require('../lib/zip-write.js');

const U1 = P.getProfile('snapmaker-u1');

test('a retarget stays inside one config family; generic goes anywhere', () => {
  const prusa = P.listProfiles().find((p) => p.flavour === 'prusa');
  const bambu = P.listProfiles().find((p) => p.flavour === 'bambu');
  assert.ok(prusa && bambu, 'catalogue has a Prusa and a Bambu');
  assert.equal(P.compatibleWith('bambu', bambu), true);
  assert.equal(P.compatibleWith('orca', bambu), true, 'Bambu and Orca share a family');
  assert.equal(P.compatibleWith('bambu', prusa), false);
  assert.equal(P.compatibleWith('generic', prusa), true, 'an unknown source may go anywhere');
  assert.equal(P.compatibleWith('bambu', P.GENERIC), true);
  assert.equal(P.isCrossEcosystem('bambu', prusa), true);
  assert.equal(P.isCrossEcosystem('bambu', P.GENERIC), false, 'Generic is never another ecosystem');
});

test('the PrusaSlicer project path stays held until switched on', () => {
  const prusa = P.listProfiles().find((p) => p.flavour === 'prusa' && p.printerSettingsId && p.bed);
  assert.ok(prusa);
  assert.equal(P.isPrusaProjectTarget('bambu', prusa), false);
  P.prusaProjectReady = true;
  try {
    assert.equal(P.isPrusaProjectTarget('bambu', prusa), true);
    assert.equal(P.compatibleWith('bambu', prusa), true);
  } finally { P.prusaProjectReady = false; }
});

test('Full Spectrum needs a mixing printer and more colours than heads', () => {
  assert.ok(U1 && U1.supportsMixedFilament, 'the U1 mixes');
  assert.equal(P.fullSpectrumCapable('orca', U1, U1.maxColors + 1), true);
  assert.equal(P.fullSpectrumCapable('orca', U1, U1.maxColors), false, 'every colour already has a head');
  const plain = P.listProfiles().find((p) => !p.supportsMixedFilament && p.flavour === 'orca');
  if (plain) assert.equal(P.fullSpectrumCapable('orca', plain, 12), false);
  assert.equal(P.fullSpectrumCapable('prusa', U1, 12), false, 'not across ecosystems');
});

test('band-swap is Full Spectrum’s situation on a banded model', () => {
  const banded = { available: true, banded: true };
  assert.equal(P.bandSwapEligible('orca', U1, 6, banded), true);
  assert.equal(P.bandSwapEligible('orca', U1, 6, { available: true, banded: false }), false);
  assert.equal(P.bandSwapEligible('orca', U1, 6, null), false);
  assert.equal(P.bandSwapEligible('orca', U1, 2, banded), false);
});

function threeMF(colours) {
  const settings = { printer_model: 'Snapmaker U1', filament_colour: colours };
  return Z.writeZip([
    { name: '[Content_Types].xml', data: Buffer.from('<Types/>') },
    { name: '_rels/.rels', data: Buffer.from('<Relationships/>') },
    { name: '3D/3dmodel.model', data: Buffer.from('<?xml version="1.0"?><model unit="millimeter"><resources><object id="1"/></resources><build><item objectid="1"/></build></model>') },
    { name: 'Metadata/project_settings.config', data: Buffer.from(JSON.stringify(settings)) },
  ]);
}

test('the members-in halves answer exactly what the buffer versions do', () => {
  const buf = threeMF(['#FF0000', '#00FF00', '#0000FF', '#FFFFFF', '#000000', '#FFFF00']);
  const members = MF.readMembers(buf);
  assert.deepEqual(MF.analyzeMembers(members), MF.analyze(buf));
  const opts = { targetId: 'snapmaker-u1' };
  assert.deepEqual(MF.fsPreviewMembers(members, opts), MF.fsPreview(buf, opts));
  assert.deepEqual(MF.analyzeColorBandsMembers(members, {}), MF.analyzeColorBands(buf, {}));
});

test('a spool match adds the options the desktop panel always sent', () => {
  const SM = require('../lib/spool-match.js');
  assert.equal(SM.convertOptions(null), null);
  assert.equal(SM.convertOptions({ kind: 'refused', refusal: { code: 'bad-map' } }), null);
  assert.equal(SM.convertOptions({ kind: 'none', slotMap: null }), null);
  assert.deepEqual(SM.convertOptions({ kind: 'none', slotMap: null, slotSpools: [null] }),
    { slotMap: null, slotSpools: [null], spoolStrict: true });
  assert.deepEqual(SM.convertOptions({ kind: 'slotMap', slotMap: [1, 0], slotSpools: null }),
    { slotMap: [1, 0], mergeToSlots: false, spoolMerge: null, growToSlots: null, slotSpools: null, spoolStrict: true });
  const merge = { kind: 'merge', mergeToSlots: true, spoolMerge: { map: [0, 0, 1], reps: [0, 2] }, slotMap: null, slotSpools: [] };
  assert.deepEqual(SM.convertOptions(merge),
    { slotMap: null, mergeToSlots: true, spoolMerge: merge.spoolMerge, growToSlots: null, slotSpools: [], spoolStrict: true });
});

test('the mesh reader and the bed check work where there is no Buffer and print-fit loads last (the Mac)', () => {
  // JavaScriptCore, as the Mac loads the bundle: no require, no Buffer, members as strings, and
  // print-fit after mf-convert in the module list.
  const fs = require('node:fs');
  const path = require('node:path');
  const vm = require('node:vm');
  const ctx = vm.createContext({});
  vm.runInContext('globalThis.global = globalThis;', ctx);
  for (const m of ['printer-profiles', 'color-bands', 'swap-pauses', 'filament-mixer', 'mf-mesh', 'full-spectrum', 'prusa-project', 'mf-convert', 'print-fit']) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'lib', m + '.js'), 'utf8'), ctx, { filename: m + '.js' });
  }
  let tri = '', v = '';
  for (let i = 0; i < 60; i++) tri += `<triangle v1="${i}" v2="${i + 1}" v3="${i + 2}" paint_color="${(i % 6 + 1).toString(16)}"/>`;
  for (let i = 0; i < 64; i++) v += `<vertex x="${i}" y="${i * 2}" z="${i}"/>`;
  const mesh = `<?xml version="1.0"?><model unit="millimeter"><resources><object id="1" type="model"><mesh><vertices>${v}</vertices><triangles>${tri}</triangles></mesh></object></resources><build><item objectid="1"/></build></model>`;
  const settings = JSON.stringify({ printer_model: 'X1C', filament_colour: ['#FF0000', '#00FF00', '#0000FF', '#FFFF00', '#FF00FF', '#00FFFF'] });
  ctx.members = [{ name: '3D/3dmodel.model', data: mesh }, { name: 'Metadata/project_settings.config', data: settings }];
  assert.equal(vm.runInContext('typeof Buffer', ctx), 'undefined');
  const bands = vm.runInContext('KhaytMfConvert.analyzeColorBandsMembers(members, {})', ctx);
  assert.equal(bands.available, true, 'the mesh could not be read without Buffer');
  const fit = vm.runInContext('KhaytMfConvert.fitWarnings({ x: 400, y: 100, z: 50 }, KhaytPrinterProfiles.getProfile("snapmaker-u1"))', ctx);
  assert.equal(fit.length, 1, 'a model wider than the bed is warned about');
});

test('a mesh passed by name alone still analyses its colours, with no bounds', () => {
  const buf = threeMF(['#FF0000', '#00FF00']);
  const members = MF.readMembers(buf).map((m) => (/\.model$/.test(m.name)
    ? { name: m.name, size: 1 << 30 } : { name: m.name, size: m.data.length, data: m.data.toString('utf8') }));
  const a = MF.analyzeMembers(members);
  assert.equal(a.ok, true);
  assert.equal(a.colorCount, 2);
  assert.equal(a.bounds, null);
});
