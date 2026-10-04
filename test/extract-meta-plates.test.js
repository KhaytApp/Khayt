'use strict';

/**
 * A multi-plate 3MF is priced as every plate, not the first.
 *
 * Found on a real two-plate Bambu/Orca file (Adiletten.3mf) by the Mac session:
 * extractMeta took the first <plate>'s prediction (655 min) while summing every
 * plate's filament (286.39 g), and model-intake priced one plate's hours against
 * two plates' grams.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const mf = require('../lib/mf-convert.js');

const member = (text) => [{ name: 'Metadata/slice_info.config', data: Buffer.from(text, 'utf8') }];
const plate = (index, secs, filaments, weight) => `
  <plate>
    <metadata key="index" value="${index}"/>
    <metadata key="prediction" value="${secs}"/>
    ${weight != null ? `<metadata key="weight" value="${weight}"/>` : ''}
    ${filaments.map((f) => `<filament id="${f.id}" type="${f.type}" color="#fff" used_m="1" used_g="${f.g}"/>`).join('\n    ')}
  </plate>`;

test('two plates: the time and the filament both cover both plates', () => {
  const xml = `<config>${plate(1, 655 * 60, [{ id: 1, type: 'PLA', g: 150.2 }])}${plate(2, 540 * 60, [{ id: 1, type: 'PLA', g: 136.19 }])}</config>`;
  const meta = mf.extractMeta(member(xml));
  assert.equal(meta.printMinutes, 655 + 540, 'only the first plate\'s time');
  assert.equal(meta.totalGrams, 286.4);
  assert.deepEqual(meta.plates, [
    { index: 1, name: null, printTimeMins: 655, filamentGrams: 150.2, filamentType: 'PLA',
      filaments: [{ id: '1', type: 'PLA', color: '#fff', grams: 150.2, meters: 1 }] },
    { index: 2, name: null, printTimeMins: 540, filamentGrams: 136.2, filamentType: 'PLA',
      filaments: [{ id: '1', type: 'PLA', color: '#fff', grams: 136.19, meters: 1 }] },
  ]);
  assert.deepEqual(meta.filaments, [{ id: '1', type: 'PLA', color: '#fff', grams: 286.39, meters: 2 }],
    'slot 1 is one spool across both plates');
});

test('one plate: unchanged, and no plates list', () => {
  const meta = mf.extractMeta(member(`<config>${plate(1, 7200, [{ id: 1, type: 'PETG', g: 40 }, { id: 2, type: 'PETG', g: 2.5 }])}</config>`));
  assert.equal(meta.printMinutes, 120);
  assert.equal(meta.totalGrams, 42.5);
  assert.equal(meta.plates, undefined);
});

test('a plate with no used_g falls back to its weight', () => {
  const xml = `<config>${plate(1, 600, [], 12.34)}${plate(2, 600, [{ id: 1, type: 'PLA', g: 5 }])}</config>`;
  const meta = mf.extractMeta(member(xml));
  assert.equal(meta.plates[0].filamentGrams, 12.3);
  assert.equal(meta.plates[0].filamentType, null);
  assert.equal(meta.printMinutes, 20);
  assert.equal(meta.totalGrams, 17.3, 'the total counts the plate that reported only its weight');
});

test('an older writer with no <plate> blocks still reads its prediction', () => {
  assert.equal(mf.extractMeta(member('<config><metadata key="prediction" value="3600"/></config>')).printMinutes, 60);
  assert.equal(mf.extractMeta(member('<config prediction="1800"></config>')).printMinutes, 30);
});

/* ── A REAL-SHAPED PROJECT, READ BY EVERY READER ──────────────────────────
 *
 * "I uploaded a multi plate 3mf and it only shows the filament data and time
 * for one in both the print files and calculator. The calculator seems to
 * have two different values however." (tester, Oct 2026)
 *
 * test/fixtures/two-plate-bambu.gcode.3mf is a Bambu "export all sliced
 * plates" file: slice_info lists both plates, and each plate has its own
 * G-code. Before the fix model-intake took plate_1.gcode and returned 90 min /
 * 34.75 g, while the colour list (thumbnail-extract) kept plate 1's grams per
 * colour and added plate 2's new colour — 55.5 g — so the same file showed two
 * weights, neither of them the project's 67.5 g. The Mac reads the same bytes
 * in SlicerFiguresTests.twoPlateFixture and must agree with every figure here. */
const fs = require('node:fs');
const path = require('node:path');
const { intake } = require('../lib/model-intake.js');
const { colorsFromConfigs } = require('../lib/thumbnail-extract.js');
const FIXTURE = path.join(__dirname, 'fixtures', 'two-plate-bambu.gcode.3mf');

test('two-plate fixture: intake answers for the whole project, with each plate kept', () => {
  const r = intake({ filename: 'two-plate-bambu.gcode.3mf', bytes: fs.readFileSync(FIXTURE) });
  assert.equal(r.source, 'slicer');
  assert.equal(r.printTimeMins, 90 + 123, 'not plate_1.gcode\'s 90 min');
  assert.equal(r.filamentGrams, 67.5, 'not plate_1.gcode\'s 34.75 g');
  assert.deepEqual(r.plates.map((p) => [p.index, p.name, p.printTimeMins, p.filamentGrams]),
    [[1, 'Body', 90, 34.8], [2, 'Lid', 123, 32.8]]);
  assert.deepEqual(r.plates[1].filaments.map((f) => [f.id, f.type, f.color, f.grams]),
    [['1', 'PLA', '#000000', 12], ['3', 'PETG', '#C12E1F', 20.75]]);
  assert.deepEqual(r.filaments.map((f) => [f.id, f.grams]), [['1', 42.5], ['2', 4.25], ['3', 20.75]]);
});

test('two-plate fixture: the colour list adds up to the same weight as the intake', () => {
  const members = mf.readMembers(fs.readFileSync(FIXTURE));
  const sliceInfo = members.find((m) => /slice_info/.test(m.name)).data.toString('utf8');
  const { colors } = colorsFromConfigs({ sliceInfo });
  assert.deepEqual(colors.map((c) => [c.hex, c.grams]), [['#000000', 42.5], ['#FFFFFF', 4.25], ['#C12E1F', 20.75]]);
  const sum = colors.reduce((a, c) => a + c.grams, 0);
  assert.equal(Math.round(sum * 10) / 10, intake({ filename: 'a.3mf', bytes: fs.readFileSync(FIXTURE) }).filamentGrams,
    'one file, one weight — the "two different values" the tester saw');
});

test('two-plate fixture: the convert summary gives each slot its grams over both plates', () => {
  const a = mf.analyze(fs.readFileSync(FIXTURE));
  assert.equal(a.meta.printMinutes, 213);
  assert.equal(a.meta.totalGrams, 67.5);
  assert.deepEqual(a.filaments.map((f) => [f.color, f.grams]),
    [['#000000', 42.5], ['#FFFFFF', 4.25], ['#C12E1F', 20.75]],
    'three spools, not four filament tags; slot 1 over both plates');
});

test('several embedded G-codes and no slice_info: added, not the first taken', () => {
  const { writeZip } = require('../lib/zip-write.js');
  const g = (t, w) => `; BambuStudio 02.02\n; total estimated time: ${t}\n; total filament weight [g] : ${w}\n; filament_type = PLA\n`;
  const buf = writeZip([
    { name: 'Metadata/plate_1.gcode', data: Buffer.from(g('1h 0m 0s', '10'), 'utf8') },
    { name: 'Metadata/plate_2.gcode', data: Buffer.from(g('0h 30m 0s', '5.5'), 'utf8') },
  ]);
  const r = intake({ filename: 'p.3mf', bytes: buf });
  assert.equal(r.printTimeMins, 90);
  assert.equal(r.filamentGrams, 15.5);
});
