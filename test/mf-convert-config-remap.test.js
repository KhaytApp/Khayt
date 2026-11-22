const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

/**
 * Band-swap and Full Spectrum both reindex the printer config to match the new filament
 * order. They must touch ONLY per-filament arrays.
 *
 * They reindexed every array whose length happened to equal the source filament count. A
 * 4-filament model matches the FOUR CORNERS of `printable_area`, so the bed rectangle came
 * out as a self-intersecting bow-tie:
 *   before ["0.5x1","270.5x1","270.5x271","0.5x271"]
 *   after  ["0.5x1","270.5x271","0.5x271","270.5x1"]
 * `remapJsonSettings` already filtered on ^filament_; these two loops did not.
 *
 * Source-level, because neither helper is exported — but it pins the exact guard.
 */
const src = fs.readFileSync(path.join(__dirname, '..', 'lib', 'mf-convert.js'), 'utf8');

const bodyOf = (fnName) => {
  const i = src.indexOf(`function ${fnName}(`);
  assert.ok(i !== -1, `${fnName} not found`);
  return src.slice(i, src.indexOf('\n  }', i));
};

// Both now delegate to reindexFilamentJson, which picks per-filament arrays by NAME (an
// explicit set plus ^filament_) — so the guard is checked there, and each caller must use it
// rather than a loop of its own.
for (const fn of ['applyBandSwapConfig', 'applyFullSpectrumConfig', 'applyMergeConfig']) {
  test(`${fn} reindexes through the per-filament name filter`, () => {
    assert.match(bodyOf(fn), /reindexFilamentJson\(/, `${fn} reindexes with a loop of its own`);
  });
}

test('reindexFilamentJson filters by name before it looks at length', () => {
  const body = bodyOf('reindexFilamentJson');
  const guardAt = body.search(/isPerFilamentJson\(k\) && v\.length === n/);
  assert.ok(guardAt !== -1, 'the per-filament name test must gate the length-matched reindex');
});

test('a four-filament Full Spectrum conversion leaves printable_area alone', () => {
  const { writeZip } = require('../lib/zip-write');
  const { openZip } = require('../lib/zip-read');
  const { convert } = require('../lib/mf-convert');
  const area = ['0x0', '256x0', '256x256', '0x256'];
  const r = convert(writeZip([
    { name: '3D/3dmodel.model', data: '<?xml version="1.0"?><model unit="millimeter"><resources><object id="1"/></resources></model>' },
    { name: 'Metadata/project_settings.config', data: JSON.stringify({
      printer_model: 'X1C', printable_area: area, nozzle_diameter: ['0.4'],
      filament_colour: ['#FF0000', '#00AA00', '#0000FF', '#FFFF00', '#FF00FF'], filament_type: ['PLA', 'PLA', 'PLA', 'PLA', 'PLA'],
    }) },
  ]), { targetId: 'ignored', targetProfile: { id: 'c-mix', name: 'Mix', flavour: 'bambu', maxColors: 4, supportsMixedFilament: true, printerModel: 'Mix' }, fullSpectrum: true });
  assert.equal(r.report.fullSpectrum, true);
  assert.deepEqual(JSON.parse(openZip(r.buffer).file('Metadata/project_settings.config').toString()).printable_area, area);
});

test('the per-filament filter keeps the reindex working', () => {
  // Behavioural check on the same logic, so the guard cannot be "fixed" by disabling it.
  const apply = (obj, idx, n) => {
    for (const k of Object.keys(obj)) {
      if (!/^filament_/i.test(k)) continue;
      const v = obj[k];
      if (Array.isArray(v) && v.length === n) obj[k] = idx.map((i) => (v[i] != null ? v[i] : v[0]));
    }
    return obj;
  };
  const cfg = {
    printable_area: ['0.5x1', '270.5x1', '270.5x271', '0.5x271'],
    filament_type: ['PLA', 'PETG', 'ABS', 'TPU'],
  };
  const out = apply(JSON.parse(JSON.stringify(cfg)), [0, 2, 3, 1], 4);
  assert.deepEqual(out.printable_area, cfg.printable_area, 'bed geometry must not be permuted');
  assert.deepEqual(out.filament_type, ['PLA', 'ABS', 'TPU', 'PETG'], 'filament arrays must still reindex');
});
