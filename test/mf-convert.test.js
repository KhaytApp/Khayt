'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { writeZip } = require('../lib/zip-write');
const { openZip } = require('../lib/zip-read');
const { analyze, convert, readMembers, detectFlavour } = require('../lib/mf-convert');
const { encodeSolidPaint, dominantState } = require('../lib/mf-mesh');

const MODEL = '<?xml version="1.0"?><model unit="millimeter"><resources><object id="1"/></resources></model>';
const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4]);

function makeBambu3mf() {
  const proj = JSON.stringify({
    printer_model: 'OrigPrinter',
    printer_settings_id: 'Orig',
    nozzle_diameter: ['0.4'],
    filament_colour: ['#FF0000', '#00FF00', '#0000FF'],
    filament_type: ['PLA', 'PLA', 'PETG'],
  });
  return writeZip([
    { name: '[Content_Types].xml', data: '<Types/>' },
    { name: '_rels/.rels', data: '<Relationships/>' },
    { name: '3D/3dmodel.model', data: MODEL },
    { name: 'Metadata/project_settings.config', data: proj },
    { name: 'Metadata/plate_1.png', data: PNG, store: true },
  ]);
}

test('analyze detects Bambu flavour, colours and geometry', () => {
  const a = analyze(makeBambu3mf());
  assert.equal(a.ok, true);
  assert.equal(a.flavour, 'bambu');
  assert.equal(a.colorCount, 3);
  assert.equal(a.filaments[0].color, '#FF0000');
  assert.equal(a.hasGeometry, true);
});

test('analyze rejects non-3MF input', () => {
  assert.equal(analyze(Buffer.from('not a zip')).ok, false);
});

test('retarget rewrites printer profile and preserves geometry byte-for-byte', () => {
  const src = makeBambu3mf();
  const r = convert(src, { targetId: 'bambu-x1c' });
  assert.equal(r.ok, true);
  assert.equal(r.report.mode, 'retarget');
  const zip = openZip(r.buffer);
  // Geometry + thumbnail unchanged.
  assert.equal(zip.file('3D/3dmodel.model').toString('utf8'), MODEL);
  assert.deepEqual(zip.file('Metadata/plate_1.png'), PNG);
  // Printer re-profiled.
  const proj = JSON.parse(zip.file('Metadata/project_settings.config').toString('utf8'));
  assert.equal(proj.printer_model, 'Bambu Lab X1 Carbon');
  assert.ok(r.report.fieldsChanged.includes('printer_model'));
});

test('retarget with a slot map reorders every filament_* array consistently', () => {
  const src = makeBambu3mf();
  const r = convert(src, { targetId: 'snapmaker-u1', slotMap: [2, 0, 1] });
  assert.equal(r.ok, true);
  assert.ok(r.report.colorsRemapped >= 1);
  const proj = JSON.parse(openZip(r.buffer).file('Metadata/project_settings.config').toString('utf8'));
  assert.deepEqual(proj.filament_colour, ['#00FF00', '#0000FF', '#FF0000']);
  assert.deepEqual(proj.filament_type, ['PLA', 'PETG', 'PLA']); // reordered in lockstep
});

test('too many colours for the target yields a warning, not a failure', () => {
  const proj = JSON.stringify({ filament_colour: ['#111111', '#222222', '#333333', '#444444', '#555555'] });
  const src = writeZip([
    { name: '3D/3dmodel.model', data: MODEL },
    { name: 'Metadata/project_settings.config', data: proj },
  ]);
  const r = convert(src, { targetId: 'snapmaker-u1' }); // maxColors 4
  assert.equal(r.ok, true);
  assert.ok(r.report.warnings.some((w) => /support/i.test(w)));
});

test('normalize strips vendor config but keeps geometry + thumbnail', () => {
  const r = convert(makeBambu3mf(), { targetId: 'generic-3mf' });
  assert.equal(r.ok, true);
  assert.equal(r.report.mode, 'normalize');
  const zip = openZip(r.buffer);
  assert.equal(zip.file('3D/3dmodel.model').toString('utf8'), MODEL);
  assert.equal(zip.file('Metadata/project_settings.config'), null); // stripped
  assert.deepEqual(zip.file('Metadata/plate_1.png'), PNG);           // kept
});

test('convert refuses a 3MF with no geometry', () => {
  const src = writeZip([{ name: 'Metadata/project_settings.config', data: '{}' }]);
  assert.equal(convert(src, { targetId: 'bambu-x1c' }).ok, false);
});

// A mesh-bearing 3MF (footprint 300×150×20 mm) for bounds + fit checks.
const MESH = '<?xml version="1.0"?><model unit="millimeter"><resources>'
  + '<object id="1" type="model"><mesh><vertices>'
  + '<vertex x="0" y="0" z="0"/><vertex x="300" y="0" z="0"/>'
  + '<vertex x="0" y="150" z="0"/><vertex x="0" y="0" z="20"/>'
  + '</vertices><triangles/></mesh></object></resources>'
  + '<build><item objectid="1" transform="1 0 0 0 1 0 0 0 1 0 0 0"/></build></model>';

function makeMeshBambu() {
  const proj = JSON.stringify({
    printer_model: 'OrigPrinter', nozzle_diameter: ['0.4'], layer_height: 0.2,
    printable_area: ['0x0', '256x0', '256x256', '0x256'],
    filament_colour: ['#FF0000', '#00FF00'],
  });
  const slice = '<config><plate><filament id="1" color="#FF0000" used_g="12.5"/>'
    + '<filament id="2" color="#00FF00" used_g="7.5"/>'
    + '<metadata key="prediction" value="3600"/></plate></config>';
  return writeZip([
    { name: '3D/3dmodel.model', data: MESH },
    { name: 'Metadata/project_settings.config', data: proj },
    { name: 'Metadata/slice_info.config', data: slice },
  ]);
}

test('analyze surfaces source metadata: printer, bed, nozzle, grams', () => {
  const a = analyze(makeMeshBambu());
  assert.equal(a.meta.printerModel, 'OrigPrinter');
  assert.equal(a.meta.nozzle, 0.4);
  assert.deepEqual(a.meta.bed, { x: 256, y: 256 });
  assert.equal(a.meta.totalGrams, 20);
  assert.equal(a.filaments[0].grams, 12.5);
});

test('computeBounds returns the transformed model footprint', () => {
  const a = analyze(makeMeshBambu());
  assert.deepEqual(a.bounds, { x: 300, y: 150, z: 20 });
});

test('retarget warns when the model is larger than the target bed', () => {
  const r = convert(makeMeshBambu(), { targetId: 'snapmaker-u1' }); // 220×220 bed
  assert.equal(r.ok, true);
  assert.ok(r.report.warnings.some((w) => /larger than|may not fit/i.test(w)));
  assert.deepEqual(r.report.bounds, { x: 300, y: 150, z: 20 });
});

test('a big-enough target bed produces no fit warning', () => {
  const r = convert(makeMeshBambu(), { targetId: 'sovol-sv08' }); // 350×350
  assert.equal(r.ok, true);
  assert.ok(!r.report.warnings.some((w) => /fit/i.test(w)));
});

test('convert output passes the self-check (report.verified)', () => {
  assert.equal(convert(makeBambu3mf(), { targetId: 'bambu-x1c' }).report.verified, true);
  assert.equal(convert(makeBambu3mf(), { targetId: 'generic-3mf' }).report.verified, true); // normalize
});

test('cross-family retarget (Bambu → Prusa) warns and does NOT rewrite the printer model', () => {
  const src = makeBambu3mf();
  const r = convert(src, { targetId: 'prusa-mk4-mmu3' }); // prusa family ≠ bambu
  assert.equal(r.ok, true);
  assert.equal(r.report.crossFamily, true);
  assert.ok(r.report.warnings.some((w) => /different slicer format|Generic/i.test(w)));
  // The Bambu JSON must NOT get a Prusa model name written into it.
  const proj = JSON.parse(openZip(r.buffer).file('Metadata/project_settings.config').toString('utf8'));
  assert.equal(proj.printer_model, 'OrigPrinter');
  assert.ok(!r.report.fieldsChanged.includes('printer_model'));
});

test('same-family Bambu retarget writes printable_height', () => {
  const r = convert(makeMeshBambu(), { targetId: 'bambu-x1c' }); // 256×256×256
  assert.equal(r.ok, true);
  assert.equal(r.report.crossFamily, undefined);
  const proj = JSON.parse(openZip(r.buffer).file('Metadata/project_settings.config').toString('utf8'));
  assert.equal(proj.printable_height, '256');
  assert.ok(r.report.fieldsChanged.includes('printable_height'));
});

// ---------- PrusaSlicer "Full Spectrum" (ColorMix) palette read ----------
// A ColorMix file's filament_colour only lists the physical bases; the virtual (mixed) colours live in a
// *_full_spectrum.json. The converter must see ALL of them, mirroring the preview reader.
const { analyzeColorBands } = require('../lib/mf-convert');

test('extractFilaments prefers the full-spectrum palette when it is longer', () => {
  const proj = JSON.stringify({ filament_colour: ['#FF0000', '#00FF00', '#0000FF', '#FFFF00'] }); // 4 bases
  const fullSpectrum = JSON.stringify({
    physical_extruders: [
      { id: 1, color: '#FF0000' }, { id: 2, color: '#00FF00' }, { id: 3, color: '#0000FF' }, { id: 4, color: '#FFFF00' },
    ],
    virtual_extruders: [
      { id: 5, color: '#FF8000', components: [{ extruder: 1, ratio: 0.5 }, { extruder: 2, ratio: 0.5 }] },
      { id: 6, color: '#8000FF', components: [{ extruder: 1, ratio: 0.5 }, { extruder: 3, ratio: 0.5 }] },
    ],
  });
  const src = writeZip([
    { name: '3D/3dmodel.model', data: MODEL },
    { name: 'Metadata/project_settings.config', data: proj },
    { name: 'Metadata/Prusa_Slicer_full_spectrum.json', data: fullSpectrum },
  ]);
  const a = analyze(src);
  assert.equal(a.colorCount, 6, 'sees 4 physical + 2 virtual mixed colours');
  assert.equal(a.filaments[4].color, '#FF8000');
  assert.equal(a.filaments[5].color, '#8000FF');
});

test('no full_spectrum.json → filament count unchanged (narrow blast radius)', () => {
  assert.equal(analyze(makeBambu3mf()).colorCount, 3);
});

// ---------- vertical colour-band analysis on a real painted mesh ----------
// A tall model split into N vertical Z bands, each triangle solid-painted with its band's filament state.
function makeBandedPainted3mf(states) {
  // One vertical wall triangle per band, stacked up the Z axis (10 mm tall each).
  const verts = [], tris = [];
  states.forEach((s, i) => {
    const z0 = i * 10, z1 = z0 + 10, base = i * 3;
    verts.push(`<vertex x="0" y="0" z="${z0}"/>`, `<vertex x="10" y="0" z="${z0}"/>`, `<vertex x="0" y="0" z="${z1}"/>`);
    tris.push(`<triangle v1="${base}" v2="${base + 1}" v3="${base + 2}" paint_color="${encodeSolidPaint(s)}"/>`);
  });
  const model = `<?xml version="1.0"?><model unit="millimeter"><resources><object id="1" type="model"><mesh>`
    + `<vertices>${verts.join('')}</vertices><triangles>${tris.join('')}</triangles>`
    + `</mesh></object></resources><build><item objectid="1"/></build></model>`;
  const proj = JSON.stringify({ layer_height: 0.2, filament_colour: ['#FF0000', '#00FF00', '#0000FF', '#FFFF00', '#FF00FF'] });
  return writeZip([
    { name: '3D/3dmodel.model', data: model },
    { name: 'Metadata/project_settings.config', data: proj },
  ]);
}

test('analyzeColorBands detects a clean vertical stack → banded, no manual swaps', () => {
  const r = analyzeColorBands(makeBandedPainted3mf([1, 2, 3]));
  assert.equal(r.available, true);
  assert.equal(r.banded, true);
  assert.equal(r.colorCount, 3);
  assert.equal(r.manualSwaps, 0);
  assert.deepEqual(r.bands.map((b) => b.state), [1, 2, 3]);
});

test('analyzeColorBands: >4 bands produce M600 swap instructions + a custom_gcode file', () => {
  const r = analyzeColorBands(makeBandedPainted3mf([1, 2, 3, 4, 5]));
  assert.equal(r.banded, true);
  assert.equal(r.manualSwaps, 1);
  assert.equal(r.instructions.length, 1);
  assert.equal(r.instructions[0].toSlot, 5);
  assert.match(r.customGcodeXml, /gcode="M600"/);
});

test('analyzeColorBands returns available:false on a file with no readable mesh', () => {
  const r = analyzeColorBands(writeZip([{ name: 'Metadata/project_settings.config', data: '{}' }]));
  assert.equal(r.available, false);
});

test('convert bandSwap: >4-band model → all colours kept, M600 custom_gcode added, self-verifies', () => {
  const r = convert(makeBandedPainted3mf([1, 2, 3, 4, 5]), { targetId: 'snapmaker-u1', bandSwap: true });
  assert.equal(r.ok, true);
  assert.equal(r.report.bandSwap, true);
  assert.equal(r.report.bandSwaps, 1); // 5 colours on 4 heads → 1 manual swap
  assert.equal(r.report.verified, true);
  const zip = openZip(r.buffer);
  // Head palette reduced to the 4 physical heads.
  const proj = JSON.parse(zip.file('Metadata/project_settings.config').toString('utf8'));
  assert.equal(proj.filament_colour.length, 4);
  // Synthesized custom_gcode carries an M600 pause.
  const cg = zip.file('Metadata/custom_gcode_per_layer.xml');
  assert.ok(cg, 'custom_gcode_per_layer.xml present');
  assert.match(cg.toString('utf8'), /gcode="M600"/);
  // Paint codes remapped: state 5 folds onto head 0 (slot 1), so no facet references slot 5 any more.
  const model = zip.file('3D/3dmodel.model').toString('utf8');
  const states = [...model.matchAll(/paint_color="([0-9A-Fa-f]+)"/g)].map((m) => dominantState(m[1]));
  assert.ok(states.every((s) => s >= 1 && s <= 4), `all paint states fold onto ≤4 heads (got ${states})`);
  assert.ok(r.report.warnings.some((w) => /Colour-banded|manual filament swap/i.test(w)));
});

test('convert bandSwap is a no-op when the model is NOT vertically banded (falls back)', () => {
  // makeBambu3mf has a stub mesh (no real geometry) → not banded → normal retarget, no band-swap report.
  const r = convert(makeBambu3mf(), { targetId: 'snapmaker-u1', bandSwap: true });
  assert.equal(r.ok, true);
  assert.notEqual(r.report.bandSwap, true);
});

test('same-family Prusa retarget rewrites bed_shape and max_print_height', () => {
  const cfg = 'printer_model = MK3S\nnozzle_diameter = 0.4\nbed_shape = 0x0,250x0,250x210,0x210\nmax_print_height = 210\nfilament_colour = #AA0000\n';
  const src = writeZip([{ name: '3D/3dmodel.model', data: MODEL }, { name: 'Metadata/Slic3r_PE.config', data: cfg }]);
  const r = convert(src, { targetId: 'prusa-xl-5t' }); // 360×360×360
  assert.equal(r.ok, true);
  const text = openZip(r.buffer).file('Metadata/Slic3r_PE.config').toString('utf8');
  assert.match(text, /bed_shape = 0x0,360x0,360x360,0x360/);
  assert.match(text, /max_print_height = 360/);
});

test('computeBounds honours a non-mm model unit (inch → mm)', () => {
  const inchModel = MESH.replace('unit="millimeter"', 'unit="inch"');
  const src = writeZip([{ name: '3D/3dmodel.model', data: inchModel }, { name: 'Metadata/project_settings.config', data: '{}' }]);
  const a = analyze(src);
  // 300×150×20 inches → ×25.4 mm
  assert.equal(a.bounds.x, Math.round(300 * 25.4 * 10) / 10);
  assert.equal(a.bounds.y, Math.round(150 * 25.4 * 10) / 10);
});

test('computeBounds resolves a <component>-composed assembly (no false Fits)', () => {
  // Object 1 is a 10×10×10 mesh; object 2 is an assembly placing it at x+500. Footprint spans 510mm.
  const model = '<?xml version="1.0"?><model unit="millimeter"><resources>'
    + '<object id="1" type="model"><mesh><vertices>'
    + '<vertex x="0" y="0" z="0"/><vertex x="10" y="10" z="10"/>'
    + '</vertices><triangles/></mesh></object>'
    + '<object id="2" type="model"><components>'
    + '<component objectid="1" transform="1 0 0 0 1 0 0 0 1 0 0 0"/>'
    + '<component objectid="1" transform="1 0 0 0 1 0 0 0 1 500 0 0"/>'
    + '</components></object></resources>'
    + '<build><item objectid="2" transform="1 0 0 0 1 0 0 0 1 0 0 0"/></build></model>';
  const a = analyze(writeZip([{ name: '3D/3dmodel.model', data: model }, { name: 'Metadata/project_settings.config', data: '{}' }]));
  assert.equal(a.bounds.x, 510); // 0..510, not the 10 a vertex-only scan would report
  assert.equal(a.bounds.y, 10);
});

test('computeBounds resolves a split 3MF whose geometry lives in a separate .model part', () => {
  // Bambu/Orca "split" export: the root model holds only the build + an assembly of components
  // that reference an object in 3D/Objects/*.model via p:path. A single-member scan saw no
  // vertices and returned null (no fit verdict); the cross-file resolver must find the footprint.
  const root = '<?xml version="1.0"?><model unit="millimeter"><resources>'
    + '<object id="2" type="model"><components>'
    + '<component objectid="1" p:path="/3D/Objects/part1.model" transform="1 0 0 0 1 0 0 0 1 0 0 0"/>'
    + '<component objectid="1" p:path="/3D/Objects/part1.model" transform="1 0 0 0 1 0 0 0 1 500 0 0"/>'
    + '</components></object></resources>'
    + '<build><item objectid="2" transform="1 0 0 0 1 0 0 0 1 0 0 0"/></build></model>';
  const part = '<?xml version="1.0"?><model unit="millimeter"><resources>'
    + '<object id="1" type="model"><mesh><vertices>'
    + '<vertex x="0" y="0" z="0"/><vertex x="10" y="10" z="10"/>'
    + '</vertices><triangles/></mesh></object></resources></model>';
  const a = analyze(writeZip([
    { name: '3D/3dmodel.model', data: root },
    { name: '3D/Objects/part1.model', data: part },
    { name: 'Metadata/project_settings.config', data: '{}' },
  ]));
  assert.equal(a.bounds.x, 510, '0..510 across the two placed instances, resolved across members');
  assert.equal(a.bounds.y, 10);
  assert.equal(a.bounds.z, 10);
});

test('a custom target profile re-profiles without registry state', () => {
  const r = convert(makeMeshBambu(), {
    targetId: 'ignored',
    targetProfile: { id: 'custom-mybot', name: 'MyBot', flavour: 'bambu', maxColors: 4, bed: { x: 400, y: 400, z: 400 }, nozzle: 0.6, printerModel: 'MyBot' },
  });
  assert.equal(r.ok, true);
  assert.equal(r.report.mode, 'retarget');
  const proj = JSON.parse(openZip(r.buffer).file('Metadata/project_settings.config').toString('utf8'));
  assert.equal(proj.printer_model, 'MyBot');
  assert.ok(!r.report.warnings.some((w) => /fit/i.test(w))); // 400×400 fits 300×150
});

test('a custom profile can opt into Full Spectrum via supportsMixedFilament', () => {
  const base = { id: 'custom-mixer', name: 'Mixer', flavour: 'bambu', maxColors: 4, bed: { x: 400, y: 400, z: 400 }, nozzle: 0.4, printerModel: 'Mixer' };
  // Without the flag, mixing is unavailable — extra colours fall through to a plain reduce.
  const off = convert(make5colourBambu(), { targetId: 'ignored', targetProfile: base, fullSpectrum: true });
  assert.ok(!off.report.fullSpectrum, 'no FS on a custom profile that did not opt in');
  // With it, the same custom printer reproduces the 5th colour as a dithered mix.
  const on = convert(make5colourBambu(), { targetId: 'ignored', targetProfile: { ...base, supportsMixedFilament: true }, fullSpectrum: true });
  assert.equal(on.report.fullSpectrum, true, 'opt-in custom profile gets Full Spectrum');
  const proj = JSON.parse(openZip(on.buffer).file('Metadata/project_settings.config').toString('utf8'));
  assert.ok(proj.mixed_filament_definitions, 'writes mixed_filament_definitions for the custom mixer');
});

test('Prusa flavour: filament_colour list + printer_model rewrite', () => {
  const cfg = 'printer_model = MK3S\nnozzle_diameter = 0.4\nfilament_colour = #AA0000;#00BB00;#0000CC\n';
  const src = writeZip([
    { name: '3D/3dmodel.model', data: MODEL },
    { name: 'Metadata/Slic3r_PE.config', data: cfg },
  ]);
  const a = analyze(src);
  assert.equal(a.flavour, 'prusa');
  assert.equal(a.colorCount, 3);
  const r = convert(src, { targetId: 'prusa-mk4-mmu3', slotMap: [2, 1, 0] });
  const text = openZip(r.buffer).file('Metadata/Slic3r_PE.config').toString('utf8');
  assert.match(text, /printer_model = MK4ISMMU3$/m);
  assert.match(text, /filament_colour = #0000CC;#00BB00;#AA0000/);
});

test('Snapmaker Orca target: normalises Bambu enum values Orca rejects', () => {
  const proj = JSON.stringify({
    printer_model: 'X1C', nozzle_diameter: ['0.4'],
    filament_colour: ['#FF0000', '#00FF00'], filament_type: ['PLA', 'PLA'],
    ensure_vertical_shell_thickness: 'enabled',
    support_style: 'tree_organic',
  });
  const src = writeZip([
    { name: '3D/3dmodel.model', data: MODEL },
    { name: 'Metadata/project_settings.config', data: proj },
  ]);
  const r = convert(src, { targetId: 'snapmaker-u1' });
  assert.equal(r.ok, true);
  const out = JSON.parse(openZip(r.buffer).file('Metadata/project_settings.config').toString('utf8'));
  assert.equal(out.ensure_vertical_shell_thickness, 'ensure_all');
  assert.equal(out.support_style, 'default');
});

test('Snapmaker U1: writes exact bed + printer preset name (plate layout stays correct)', () => {
  const proj = JSON.stringify({
    printer_model: 'X1C', printer_settings_id: 'Bambu Lab X1 Carbon 0.4 nozzle',
    nozzle_diameter: ['0.4'], filament_colour: ['#FF0000', '#00FF00'], filament_type: ['PLA', 'PLA'],
  });
  const src = writeZip([
    { name: '3D/3dmodel.model', data: MODEL },
    { name: 'Metadata/project_settings.config', data: proj },
  ]);
  const out = JSON.parse(openZip(convert(src, { targetId: 'snapmaker-u1' }).buffer)
    .file('Metadata/project_settings.config').toString('utf8'));
  assert.deepEqual(out.printable_area, ['0.5x1', '270.5x1', '270.5x271', '0.5x271']);
  assert.equal(out.printable_height, '270.05');
  assert.equal(out.printer_settings_id, 'Snapmaker U1 (0.4 nozzle)');
});

test('Snapmaker U1: filament presets default to Generic <type>; per-slot picks override', () => {
  const proj = JSON.stringify({
    printer_model: 'X1C', nozzle_diameter: ['0.4'],
    filament_colour: ['#FF0000', '#00FF00'], filament_settings_id: ['Bambu PLA Basic @BBL X1C', 'Bambu PLA Basic @BBL X1C'],
    filament_type: ['PLA', 'PETG'],
  });
  const src = writeZip([
    { name: '3D/3dmodel.model', data: MODEL },
    { name: 'Metadata/project_settings.config', data: proj },
  ]);
  const def = JSON.parse(openZip(convert(src, { targetId: 'snapmaker-u1' }).buffer)
    .file('Metadata/project_settings.config').toString('utf8'));
  assert.deepEqual(def.filament_settings_id, ['Generic PLA', 'Generic PETG']);
  const picked = JSON.parse(openZip(convert(src, { targetId: 'snapmaker-u1', filaments: [{ name: 'Snapmaker PLA Matte @U1', type: 'PLA' }, null] }).buffer)
    .file('Metadata/project_settings.config').toString('utf8'));
  assert.equal(picked.filament_settings_id[0], 'Snapmaker PLA Matte @U1');
  assert.equal(picked.filament_settings_id[1], 'Generic PETG');
});

test('Snapmaker U1: overlays native machine + process settings when the slicer DB is present', () => {
  const orca = require('../lib/orca-db');
  if (!orca.available() || !orca.listU1Processes().length) return; // no installed slicer → skip
  const proj = JSON.stringify({
    printer_model: 'X1C', gcode_flavor: 'marlin', nozzle_diameter: ['0.4'],
    filament_colour: ['#FF0000', '#00FF00'], filament_type: ['PLA', 'PLA'],
    machine_start_gcode: 'BAMBU_START',
  });
  const src = writeZip([
    { name: '3D/3dmodel.model', data: MODEL },
    { name: 'Metadata/project_settings.config', data: proj },
  ]);
  const r = convert(src, { targetId: 'snapmaker-u1' });
  const out = JSON.parse(openZip(r.buffer).file('Metadata/project_settings.config').toString('utf8'));
  assert.equal(r.report.u1Native, true);
  assert.notEqual(out.machine_start_gcode, 'BAMBU_START'); // replaced with the U1's own G-code
  assert.match(String(out.print_settings_id), /@Snapmaker U1/i);
  assert.equal(out.printer_settings_id, 'Snapmaker U1 (0.4 nozzle)');
});

test('Snapmaker U1: multi-plate layout is re-tiled onto the target bed', () => {
  // Two plates, objects positioned on a 256-bed grid (plate 2 offset by ~307mm).
  const proj = JSON.stringify({ printer_model: 'X1C', nozzle_diameter: ['0.4'],
    printable_area: ['0x0', '256x0', '256x256', '0x256'],
    filament_colour: ['#FF0000'], filament_type: ['PLA'] });
  const model = `<?xml version="1.0"?><model><resources>
    <object id="2" type="model"><mesh><vertices><vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="0" y="1" z="0"/></vertices><triangles><triangle v1="0" v2="1" v3="2"/></triangles></mesh></object>
    <object id="4" type="model"><mesh><vertices><vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="0" y="1" z="0"/></vertices><triangles><triangle v1="0" v2="1" v3="2"/></triangles></mesh></object>
    </resources><build>
    <item objectid="2" transform="1 0 0 0 1 0 0 0 1 128 128 0"/>
    <item objectid="4" transform="1 0 0 0 1 0 0 0 1 435 128 0"/>
    </build></model>`;
  const msc = `<?xml version="1.0"?><config>
    <plate><metadata key="plater_id" value="1"/><model_instance><metadata key="object_id" value="2"/></model_instance></plate>
    <plate><metadata key="plater_id" value="2"/><model_instance><metadata key="object_id" value="4"/></model_instance></plate>
    </config>`;
  const src = writeZip([
    { name: '3D/3dmodel.model', data: model },
    { name: 'Metadata/project_settings.config', data: proj },
    { name: 'Metadata/model_settings.config', data: msc },
  ]);
  const r = convert(src, { targetId: 'snapmaker-u1' });
  assert.equal(r.report.platesRetiled, 2);
  const out = openZip(r.buffer).file('3D/3dmodel.model').toString('utf8');
  const tx = [...out.matchAll(/objectid="(\d+)"\s+transform="([^"]+)"/g)]
    .map((m) => ({ id: m[1], x: +m[2].trim().split(/\s+/)[9] }));
  const o2 = tx.find((t) => t.id === '2').x, o4 = tx.find((t) => t.id === '4').x;
  assert.ok(Math.abs(o2 - 135) < 1, `plate-1 object centred on 270 bed (got ${o2})`);
  // plate 2 re-tiled to the 270-bed stride (270 + 51 gap = 321), so ~135 + 321
  assert.ok(o4 > 400 && o4 < 470, `plate-2 object re-tiled at target stride (got ${o4})`);
});

// --- Full Spectrum gating (regression: mixing is a U1 hardware feature, NOT every orca-flavour target) ---
function make5colourBambu() {
  const proj = JSON.stringify({
    printer_model: 'X1C', nozzle_diameter: ['0.4'],
    filament_colour: ['#FF0000', '#00AA00', '#0000FF', '#FFFF00', '#FF00FF'],
    filament_type: ['PLA', 'PLA', 'PLA', 'PLA', 'PLA'],
  });
  return writeZip([
    { name: '3D/3dmodel.model', data: MODEL },
    { name: 'Metadata/project_settings.config', data: proj },
  ]);
}

test('Full Spectrum applies on a Snapmaker U1 (4 slots, 5 colours)', () => {
  const r = convert(make5colourBambu(), { targetId: 'snapmaker-u1', fullSpectrum: true });
  assert.equal(r.ok, true);
  assert.equal(r.report.fullSpectrum, true);
  const proj = JSON.parse(openZip(r.buffer).file('Metadata/project_settings.config').toString('utf8'));
  assert.equal(proj.filament_colour.length, 4, 'keeps exactly 4 physical heads');
  assert.ok(proj.mixed_filament_definitions, 'writes mixed_filament_definitions');
});

test('Full Spectrum is refused on a single-extruder orca printer (Sovol SV08)', () => {
  const r = convert(make5colourBambu(), { targetId: 'sovol-sv08', fullSpectrum: true });
  assert.equal(r.ok, true);
  assert.ok(!r.report.fullSpectrum, 'FS not applied to a printer that cannot mix');
  const proj = JSON.parse(openZip(r.buffer).file('Metadata/project_settings.config').toString('utf8'));
  assert.ok(!proj.mixed_filament_definitions, 'no mixed_filament_definitions on a non-mixing printer');
});

// A real painted mesh (not the bare MODEL): 5 filaments, geometry carrying a solid
// paint_color for each of the 1-based states 1..5. Exercises the full FS pipeline end to
// end — plan → remapModelPaint over actual paint codes → self-check — and guards against a
// remap that corrupts geometry, drops paint, or leaves a state pointing past the last slot.
function make5colourPaintedU1() {
  const verts = [];
  for (let i = 0; i < 15; i++) verts.push(`<vertex x="${i}" y="${(i * 7) % 13}" z="${(i * 3) % 11}"/>`);
  const tris = [1, 2, 3, 4, 5].map((s, i) =>
    `<triangle v1="${i * 3}" v2="${i * 3 + 1}" v3="${i * 3 + 2}" paint_color="${encodeSolidPaint(s)}"/>`).join('');
  const model = `<?xml version="1.0"?><model unit="millimeter"><resources><object id="1" type="model">`
    + `<mesh><vertices>${verts.join('')}</vertices><triangles>${tris}</triangles></mesh></object></resources>`
    + `<build><item objectid="1" transform="1 0 0 0 1 0 0 0 1 0 0 0"/></build></model>`;
  const proj = JSON.stringify({
    printer_model: 'X1C', nozzle_diameter: ['0.4'],
    filament_colour: ['#FF0000', '#00AA00', '#0000FF', '#FFFF00', '#FF00FF'],
    filament_type: ['PLA', 'PLA', 'PLA', 'PLA', 'PLA'],
  });
  return writeZip([
    { name: '3D/3dmodel.model', data: model },
    { name: 'Metadata/project_settings.config', data: proj },
  ]);
}

test('Full Spectrum on a painted mesh preserves geometry and remaps every paint code into a real slot', () => {
  const r = convert(make5colourPaintedU1(), { targetId: 'snapmaker-u1', fullSpectrum: true });
  assert.equal(r.ok, true);
  assert.equal(r.report.fullSpectrum, true);
  assert.ok(r.report.fullSpectrumMixes >= 1, 'at least one colour realised as a mix');
  assert.equal(r.report.verified, true, 'self-check re-validated the FS output (4 colours + geometry)');

  const out = openZip(r.buffer).file('3D/3dmodel.model').toString('utf8');
  // Geometry byte-count invariants: FS only rewrites paint_color, never mesh topology.
  assert.equal((out.match(/<vertex\b/g) || []).length, 15, 'all vertices preserved');
  assert.equal((out.match(/<triangle\b/g) || []).length, 5, 'all triangles preserved');

  // Every painted facet survives, stays a valid hex code, and points at a slot that exists
  // (physical 1..4 plus the virtual mix slots 5..4+mixes) — never a dangling reference.
  const codes = [...out.matchAll(/paint_color="([0-9A-Fa-f]+)"/g)].map((m) => m[1]);
  assert.equal(codes.length, 5, 'all paint_color attributes survive the remap');
  const maxSlot = 4 + r.report.fullSpectrumMixes;
  for (const c of codes) {
    const s = dominantState(c);
    assert.ok(s >= 1 && s <= maxSlot, `paint state ${s} within [1,${maxSlot}]`);
  }
});

test('planFullSpectrum honours a non-4 physical head count', () => {
  const fs = require('../lib/full-spectrum');
  const colors = ['#FF0000', '#00AA00', '#0000FF', '#FFFF00', '#FF00FF', '#00FFFF'];
  const plan = fs.planFullSpectrum(colors, [], { maxPhysical: 3 });
  assert.equal(plan.physical.length, 3, 'exactly 3 physical heads');
  // Every virtual (mix) slot must be numbered after the physical heads (>= 4), never colliding with 1..3.
  const virtuals = Object.values(plan.newOf).filter((v) => v > 3);
  assert.ok(virtuals.every((v) => v >= 4), 'virtual slots start after the physical heads');
});

/**
 * Which members get read first, and why it decides whether a file converts.
 *
 * A real 229 MB Orca project — a six-colour Spiderman poster — converted to
 * nothing. readMembers walked the archive in order, spent all 1 GiB of its
 * zip-bomb budget on .model geometry, and stopped at member 111 of 117. The
 * configs that say what the file IS sit at 113 and 114, so detectFlavour saw no
 * config member, answered 'generic', extractFilaments found none, and six
 * filaments became zero.
 *
 * Nothing threw. Every step behaved correctly on the members it was handed.
 * With the order fixed the same file reads as bambu with six colours.
 *
 * The budget cannot be exhausted from a unit test without inflating a gigabyte,
 * so the property tested here is the one that produced the bug: identity before
 * geometry, whatever the archive's own order.
 */
test('the members that identify a file are read before the ones that fill it', () => {
  const zip = writeZip([
    // Deliberately archive-ordered the way the failing file was: mesh first,
    // configs last. In archive order the configs come back last, and behind a
    // large enough mesh they never come back at all.
    { name: '3D/3dmodel.model', data: Buffer.from('<model/>', 'utf8') },
    { name: '3D/Objects/object_1.model', data: Buffer.from('<mesh/>', 'utf8') },
    { name: 'Metadata/plate_1.png', data: Buffer.from([0x89, 0x50, 0x4e, 0x47]) },
    { name: 'Metadata/project_settings.config', data: Buffer.from('{"filament_colour":["#D90000"]}', 'utf8') },
    { name: 'Metadata/slice_info.config', data: Buffer.from('; generated by OrcaSlicer', 'utf8') },
  ]);

  const members = readMembers(zip);
  const names = members.map((m) => m.name);
  assert.equal(names.length, 5, 'every member should still be read');

  const firstMesh = names.findIndex((n) => /\.model$/i.test(n));
  const lastIdentity = names.reduce((acc, n, i) => (/\.model$/i.test(n) ? acc : i), -1);
  assert.ok(lastIdentity < firstMesh,
    `configs must precede meshes so the budget cannot starve them — got ${JSON.stringify(names)}`);

  // And the point of the ordering: the file is still recognised for what it is.
  assert.equal(detectFlavour(members), 'orca');
});
