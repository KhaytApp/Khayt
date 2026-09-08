'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { printFacts } = require('../lib/print-facts');

/** An Orca/Bambu project config with the keys these files really carry. */
function orca(over) {
  return JSON.stringify(Object.assign({
    printer_model: 'Snapmaker U1',
    layer_height: '0.12',
    nozzle_diameter: ['0.4', '0.4', '0.4', '0.4'],
    filament_type: ['PLA', 'PLA', 'PLA', 'PLA'],
    sparse_infill_density: '15%',
    enable_support: '0',
    support_type: 'tree(auto)',
  }, over || {}));
}

/** A model_settings.config with one `<object>` per set of overrides given. */
function model(objects) {
  const body = objects.map((o, i) => {
    const meta = Object.keys(o)
      .map((k) => `    <metadata key="${k}" value="${o[k]}"/>`).join('\n');
    return `  <object id="${i + 2}">\n` +
           `    <metadata key="name" value="thing ${i}"/>\n${meta}\n` +
           `    <part id="1" subtype="normal_part">\n` +
           `      <metadata key="sparse_infill_density" value="1%"/>\n` +
           `    </part>\n  </object>`;
  }).join('\n');
  return `<?xml version="1.0" encoding="UTF-8"?>\n<config>\n${body}\n</config>`;
}

test('reads what an Orca project says', () => {
  const f = printFacts({ projectSettings: orca() });
  assert.equal(f.printer, 'Snapmaker U1');
  assert.equal(f.layerHeight, 0.12);
  assert.equal(f.nozzle, 0.4);
  assert.equal(f.nozzleVaries, false);
  assert.deepEqual(f.materials, ['PLA']);   // four identical slots are one material
  assert.equal(f.infill, '15%');
  assert.equal(f.source, 'orca');
});

test("an object's own infill beats the project's", () => {
  // The real case: every king plate. The project says 15% and the object says
  // 100%, and 15% would be a straight lie about what the file prints.
  const f = printFacts({
    projectSettings: orca(),
    modelSettings: model([{ sparse_infill_density: '100%' }]),
  });
  assert.equal(f.infill, '100%');
  assert.equal(f.infillVaries, false);
});

test('objects that disagree are reported as disagreeing, not as the first one', () => {
  const f = printFacts({
    projectSettings: orca(),
    modelSettings: model([{ sparse_infill_density: '100%' }, {}]),
  });
  assert.equal(f.infillVaries, true);
  assert.equal(f.objects, 2);
});

test('an object saying nothing takes the project value, so a quiet plate is not "mixed"', () => {
  const f = printFacts({ projectSettings: orca(), modelSettings: model([{}, {}, {}]) });
  assert.equal(f.infill, '15%');
  assert.equal(f.infillVaries, false);
  assert.equal(f.objects, 3);
});

test("a part's settings are not read as the object's", () => {
  // Every `<object>` above contains a `<part>` carrying 1% infill. A regex that
  // did not stop at the part would report 1%, or call the plate mixed.
  const f = printFacts({ projectSettings: orca(), modelSettings: model([{}]) });
  assert.equal(f.infill, '15%');
  assert.equal(f.infillVaries, false);
});

test('support off means no support style, however loudly support_type is set', () => {
  // Every one of these files carries a support_type whether or not support is
  // on. "tree (auto)" on a model that prints without support is the most
  // misleading thing this module could say.
  const f = printFacts({ projectSettings: orca({ enable_support: '0' }) });
  assert.equal(f.support, false);
  assert.equal(f.supportStyle, null);
});

test('support on reports how', () => {
  const f = printFacts({ projectSettings: orca({ enable_support: '1' }) });
  assert.equal(f.support, true);
  assert.equal(f.supportStyle, 'tree(auto)');
});

test('an object can switch support off for itself', () => {
  const f = printFacts({
    projectSettings: orca({ enable_support: '1' }),
    modelSettings: model([{ enable_support: '0' }]),
  });
  assert.equal(f.support, false);
  assert.equal(f.supportStyle, null);
});

test('slots that disagree about the nozzle say so instead of picking one', () => {
  const f = printFacts({ projectSettings: orca({ nozzle_diameter: ['0.4', '0.6'] }) });
  assert.equal(f.nozzleVaries, true);
  assert.equal(f.nozzle, 0.4);   // still the first, for anyone who wants a number
});

test('two materials are two materials', () => {
  const f = printFacts({ projectSettings: orca({ filament_type: ['PLA', 'PETG', 'PLA'] }) });
  assert.deepEqual(f.materials, ['PLA', 'PETG']);
});

test('PrusaSlicer spells the same ideas differently', () => {
  // Key names read off this Mac's own PrusaSlicer profiles: `fill_density`
  // rather than `sparse_infill_density`, `support_material` rather than
  // `enable_support`. Reading an Orca name out of a Prusa file finds nothing.
  const prusa = [
    'layer_height = 0.2',
    'first_layer_height = 0.2',
    'fill_density = 10%',
    'support_material = 1',
    'support_material_auto = 0',
    'support_material_style = snug',
    'nozzle_diameter = 0.4',
    'printer_model = COREONE',
    'filament_type = PETG',
  ].join('\n');
  const f = printFacts({ prusa });
  assert.equal(f.source, 'prusa');
  assert.equal(f.printer, 'COREONE');
  assert.equal(f.layerHeight, 0.2);
  assert.equal(f.infill, '10%');
  assert.equal(f.support, true);
  assert.equal(f.supportStyle, 'snug');
  assert.deepEqual(f.materials, ['PETG']);
});

test('a multi-material Prusa file separates with a semicolon', () => {
  const f = printFacts({ prusa: 'filament_type = PLA;PETG;PLA\nnozzle_diameter = 0.4;0.4' });
  assert.deepEqual(f.materials, ['PLA', 'PETG']);
  assert.equal(f.nozzleVaries, false);
});

test('a CAD 3MF has no opinion about printing, and says nothing rather than guessing', () => {
  const f = printFacts({});
  assert.equal(f.source, null);
  assert.equal(f.printer, null);
  assert.equal(f.infill, null);
  assert.equal(f.support, null);
  assert.deepEqual(f.materials, []);
});

test('nothing here throws, whatever it is handed', () => {
  // A preview must still show the picture when the settings are rubbish.
  for (const bad of [null, undefined, {}, { projectSettings: 'not json' },
                     { projectSettings: '[]' }, { projectSettings: 'null' },
                     { modelSettings: '<config><object>' },
                     { projectSettings: orca({ layer_height: 'thick' }) }]) {
    assert.doesNotThrow(() => printFacts(bad));
  }
  assert.equal(printFacts({ projectSettings: orca({ layer_height: 'thick' }) }).layerHeight, null);
});

test('the count of objects survives a file with no settings at all', () => {
  const f = printFacts({ modelSettings: model([{}, {}]) });
  assert.equal(f.objects, 2);
  assert.equal(f.source, null);
});
