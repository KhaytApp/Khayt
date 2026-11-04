'use strict';

/**
 * Real figures for Bambu jobs: the SLICED grams of the plate that ran, and the
 * time Khayt watched the job take.
 *
 * NOT VERIFIED ON A REAL PRINTER — the bench has no Bambu. The slice_info below
 * is written to the shape Bambu Studio 1.9/2.x writes (header, one <plate> per
 * plate, metadata key/value pairs, per-filament used_g/used_m), and the report
 * fields are the ones `parseBambuReport` already reads.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const S = require('../lib/bambu-sliced.js');
const A = require('../lib/printer-actuals.js');
const C = require('../lib/printer-poll-cache.js');
const bambu = require('../lib/bambu.js');
const { writeZip } = require('../lib/zip-write.js');

const SLICE_INFO = `<?xml version="1.0" encoding="UTF-8"?>
<config>
  <header>
    <header_item key="X-BBL-Client-Type" value="slicer"/>
    <header_item key="X-BBL-Client-Version" value="02.01.01.52"/>
  </header>
  <plate>
    <metadata key="index" value="1"/>
    <metadata key="printer_model_id" value="C12"/>
    <metadata key="nozzle_diameters" value="0.4"/>
    <metadata key="timelapse_type" value="0"/>
    <metadata key="prediction" value="5420"/>
    <metadata key="weight" value="41.83"/>
    <metadata key="outside" value="false"/>
    <metadata key="support_used" value="false"/>
    <object identify_id="141" name="Bracket.stl" skipped="false" />
    <filament id="1" tray_info_idx="GFA00" type="PLA" color="#FFFFFF" used_m="13.91" used_g="41.83" />
  </plate>
  <plate>
    <metadata key="index" value="2"/>
    <metadata key="prediction" value="9876"/>
    <metadata key="weight" value="77.30"/>
    <filament id="1" type="PLA" color="#FFFFFF" used_m="20.10" used_g="60.10" />
    <filament id="3" type="PETG" color="#000000" used_m="5.4" used_g="17.2" />
  </plate>
</config>`;

const threeMf = (members) => writeZip(members.map(([name, text]) => ({ name, data: Buffer.from(text, 'utf8') })));

test('parseSliceInfo reads every plate: index, grams, prediction, filaments', () => {
  const plates = S.parseSliceInfo(SLICE_INFO);
  assert.equal(plates.length, 2);
  assert.deepEqual(plates[0], {
    index: 1, grams: 41.83, predictionS: 5420,
    filaments: [{ id: '1', type: 'PLA', color: '#FFFFFF', usedG: 41.83, usedM: 13.91 }],
  });
  assert.equal(plates[1].index, 2);
  assert.equal(plates[1].grams, 77.3, 'used_g summed across the plate\'s filaments');
  assert.equal(plates[1].predictionS, 9876);
});

test('weight is the fallback when no filament carries used_g', () => {
  const [p] = S.parseSliceInfo('<config><plate><metadata key="index" value="4"/><metadata key="weight" value="12.5"/></plate></config>');
  assert.equal(p.index, 4);
  assert.equal(p.grams, 12.5);
  assert.equal(p.predictionS, null);
});

test('a plate with no usable index is dropped, never renumbered', () => {
  const plates = S.parseSliceInfo(`<config>
    <plate><metadata key="weight" value="5"/></plate>
    <plate><metadata key="index" value="1e20"/><metadata key="weight" value="5"/></plate>
    <plate><metadata key="index" value="2"/><metadata key="weight" value="5"/></plate>
    <plate><metadata key="index" value="2"/><metadata key="weight" value="9"/></plate>
  </config>`);
  assert.deepEqual(plates.map((p) => p.index), [2]);
  assert.equal(plates[0].grams, 5, 'the first plate 2, not the repeat');
});

test('garbage in, nothing out', () => {
  assert.deepEqual(S.parseSliceInfo(''), []);
  assert.deepEqual(S.parseSliceInfo(null), []);
  assert.deepEqual(S.parseSliceInfo('<plate><metadata key="index" value="1"/><metadata key="weight" value="-3"/></plate>'),
    [{ index: 1, grams: null, predictionS: null, filaments: [] }]);
});

test('slicedForPlate: the named plate or nothing; unnamed only when there is one', () => {
  const plates = S.parseSliceInfo(SLICE_INFO);
  assert.deepEqual(S.slicedForPlate(plates, 2), { plate: 2, grams: 77.3, predictionS: 9876 });
  assert.equal(S.slicedForPlate(plates, 3), null, 'a plate the file does not have');
  assert.equal(S.slicedForPlate(plates, null), null, 'two plates and none named is a guess');
  assert.deepEqual(S.slicedForPlate([plates[0]], null), { plate: 1, grams: 41.83, predictionS: 5420 });
});

test('plateToStart: plate 1 when the file has it, else the plate it does have', () => {
  assert.equal(S.plateToStart(['Metadata/plate_1.gcode', 'Metadata/plate_2.gcode']), 1);
  assert.equal(S.plateToStart(['3D/3dmodel.model', 'Metadata/plate_3.gcode', 'Metadata/plate_3.png']), 3);
  assert.equal(S.plateToStart(['3D/3dmodel.model']), 1);
  assert.equal(S.plateToStart(null), 1);
});

test('sameJob matches the name Khayt sent, with or without the print-file extension', () => {
  assert.ok(S.sameJob('khayt-abc.gcode.3mf', 'khayt-abc.gcode.3mf'));
  assert.ok(S.sameJob('khayt-abc', 'khayt-abc.gcode.3mf'));
  assert.ok(S.sameJob('/sdcard/KHAYT-ABC.3mf', 'khayt-abc.3mf'));
  assert.ok(!S.sameJob('someone-else.3mf', 'khayt-abc.3mf'));
  assert.ok(!S.sameJob('', 'khayt-abc.3mf'));
});

test('slicedPlan reads a real 3MF zip: the plate it will start and every plate\'s figures', () => {
  const buf = threeMf([
    ['3D/3dmodel.model', '<model/>'],
    ['Metadata/plate_2.gcode', '; plate 2'],
    ['Metadata/slice_info.config', SLICE_INFO],
  ]);
  const plan = bambu.slicedPlan(buf);
  assert.equal(plan.plate, 2, 'an exported plate-2-only file starts plate 2');
  assert.equal(plan.plates.length, 2);
  const none = bambu.slicedPlan(Buffer.from('G28\nG1 X0\n'));
  assert.deepEqual(none, { plate: 1, plates: [] }, 'a plain G-code still sends, claiming nothing');
});

test('projectFileCommand starts the plate it is given (and plate 1 otherwise)', () => {
  assert.equal(bambu.projectFileCommand('a.3mf', 3).print.param, 'Metadata/plate_3.gcode');
  assert.equal(bambu.projectFileCommand('a.3mf').print.param, 'Metadata/plate_1.gcode');
  assert.equal(bambu.projectFileCommand('a.3mf', 0).print.param, 'Metadata/plate_1.gcode');
  assert.equal(bambu.projectFileCommand('a.3mf', 2).print.subtask_name, 'a.3mf');
});

test('extractActuals(bambu) labels the file\'s figures SLICED, and claims nothing without them', () => {
  const bare = A.extractActuals('bambu', { print: {} });
  assert.equal(bare.filamentGrams, null);
  assert.equal(bare.durationS, null);
  assert.equal(bare.source, 'bambu');

  const a = A.extractActuals('bambu', {}, { sliced: { plate: 2, grams: 77.3, predictionS: 9876 } });
  assert.equal(a.filamentGrams, 77.3);
  assert.equal(a.gramsBasis, 'sliced');
  assert.equal(a.durationS, 9876);
  assert.equal(a.timeBasis, 'sliced');
  assert.equal(a.source, 'bambu-sliced');
  assert.equal(a.plate, 2);
});

test('withSliced lays the figures on only while the printer runs the job Khayt sent', () => {
  const record = { remoteName: 'khayt-xyz.gcode.3mf', plate: 1, plates: S.parseSliceInfo(SLICE_INFO) };
  const running = { ok: true, state: 'Printing', progress: 40, filename: 'khayt-xyz.gcode.3mf', type: 'bambu' };
  const got = S.withSliced(running, record, A.extractActuals);
  assert.equal(got.actuals.filamentGrams, 41.83);
  assert.equal(got.actuals.gramsBasis, 'sliced');
  const other = { ...running, filename: 'started-from-bambu-studio' };
  assert.equal(S.withSliced(other, record, A.extractActuals), other, 'someone else\'s job gets nothing');
  assert.equal(S.withSliced(running, null, A.extractActuals), running);
});

// ── The completion sheet's prefill ─────────────────────────────────────────

test('prefillActuals offers sliced figures and never calls them measured', () => {
  const now = 10_000_000;
  const completion = { at: now - 1000, filename: 'khayt-xyz.gcode.3mf',
    actuals: { filamentMm: null, filamentGrams: 41.83, durationS: 5420, source: 'bambu-sliced',
      gramsBasis: 'sliced', timeBasis: 'sliced', plate: 1 } };
  const pre = A.prefillActuals({ estimate: { printTime: 2, weightG: 50 }, completion, now });
  assert.equal(pre.weightG, 41.8);
  assert.equal(pre.weightMeasured, false);
  assert.equal(pre.weightSliced, true);
  assert.equal(pre.timeMeasured, false);
  assert.equal(pre.timeSliced, true);
  assert.equal(pre.measured, false, 'nothing here was measured');
  assert.equal(pre.sliced, true);
  assert.equal(pre.plate, 1);
  assert.equal(pre.staleReason, null);
  // A failed print is never handed the whole plate's grams.
  assert.equal(A.measuredSoFar({ estimate: { weightG: 50 }, completion, now }), null);
});

test('observed time is measured; sliced grams beside it stay sliced', () => {
  const now = 10_000_000;
  const completion = { at: now - 1000, filename: 'k.3mf',
    actuals: { filamentGrams: 41.83, durationS: 5500, source: 'bambu-sliced',
      gramsBasis: 'sliced', timeBasis: 'observed', plate: 1 } };
  const pre = A.prefillActuals({ estimate: { printTime: 2, weightG: 50 }, completion, now });
  assert.equal(pre.timeMeasured, true);
  assert.equal(pre.timeSliced, false);
  assert.equal(pre.weightMeasured, false);
  assert.equal(pre.weightSliced, true);
  assert.equal(pre.measured, true);
});

test('other printers are unchanged: no basis means measured', () => {
  const now = 10_000_000;
  const completion = { at: now - 1000, filename: 'b.gcode',
    actuals: { filamentGrams: 41.83, durationS: 11560, source: 'moonraker' } };
  const pre = A.prefillActuals({ estimate: { printTime: 2, weightG: 50 }, completion, now });
  assert.equal(pre.timeMeasured, true);
  assert.equal(pre.weightMeasured, true);
  assert.equal(pre.measured, true);
  assert.equal(pre.sliced, false);
});

// ── Khayt's own clock for a Bambu job ──────────────────────────────────────

const bambuStatus = (state, progress, extra = {}) => ({ ok: true, state, progress, filename: 'khayt-xyz.gcode.3mf', type: 'bambu', ...extra });

/** Polls every 30 s, as the desktop does: each segment holds one status for its span. */
function run(steps) {
  let entry;
  const POLL = 30_000;
  for (let i = 0; i < steps.length; i++) {
    const [t, s] = steps[i];
    const next = i + 1 < steps.length ? steps[i + 1][0] : t + 1;
    for (let at = t; at < next; at += POLL) entry = C.mergePollSuccess(entry, s, at);
  }
  return entry;
}

test('a Bambu watched from start to finish gets its observed duration, pauses taken off', () => {
  const T0 = 1_000_000;
  const e = run([
    [T0, bambuStatus('Preparing', 0)],
    [T0 + 30_000, bambuStatus('Printing', 0)],         // start seen here
    [T0 + 30_000 + 3_600_000, bambuStatus('Printing', 60)],
    [T0 + 30_000 + 3_630_000, bambuStatus('Paused', 60)],
    [T0 + 30_000 + 4_230_000, bambuStatus('Printing', 61)], // 600 s paused
    [T0 + 30_000 + 5_430_000, bambuStatus('Finished', 100)],
  ]);
  assert.ok(e.lastCompleted, 'the edge out of printing froze a completion');
  assert.equal(e.lastCompleted.actuals.durationS, 5_430 - 600);
  assert.equal(e.lastCompleted.actuals.timeBasis, 'observed');
  assert.equal(e.jobClock, undefined, 'the clock goes with the job');
});

test('the observed time replaces a slice prediction and keeps the sliced grams', () => {
  const T0 = 1_000_000;
  const sliced = A.extractActuals('bambu', {}, { sliced: { plate: 1, grams: 41.83, predictionS: 5420 } });
  const e = run([
    [T0, bambuStatus('Idle', 0)],
    [T0 + 10_000, bambuStatus('Printing', 1, { actuals: sliced })],
    [T0 + 10_000 + 6_000_000, bambuStatus('Printing', 99, { actuals: sliced })],
    [T0 + 10_000 + 6_030_000, bambuStatus('Finished', 100, { actuals: sliced })],
  ]);
  const a = e.lastCompleted.actuals;
  assert.equal(a.durationS, 6_030);
  assert.equal(a.timeBasis, 'observed');
  assert.equal(a.filamentGrams, 41.83);
  assert.equal(a.gramsBasis, 'sliced');
  assert.equal(a.source, 'bambu-sliced');
});

test('a job Khayt opened on half done is not timed; the slice prediction stands, labelled sliced', () => {
  const T0 = 1_000_000;
  const sliced = A.extractActuals('bambu', {}, { sliced: { plate: 1, grams: 41.83, predictionS: 5420 } });
  const e = run([
    [T0, bambuStatus('Printing', 47, { actuals: sliced })],
    [T0 + 3_000_000, bambuStatus('Finished', 100, { actuals: sliced })],
  ]);
  assert.equal(e.lastCompleted.actuals.durationS, 5420);
  assert.equal(e.lastCompleted.actuals.timeBasis, 'sliced');
});

test('a gap in the watch longer than the limit is no observation', () => {
  const T0 = 1_000_000;
  let e = run([[T0, bambuStatus('Idle', 0)], [T0 + 10_000, bambuStatus('Printing', 0)]]);
  e = C.mergePollFailure(e, 'timeout', T0 + 20_000);
  e = C.mergePollSuccess(e, bambuStatus('Printing', 80), T0 + 10_000 + C.CLOCK_MAX_GAP_MS + 60_000);
  e = C.mergePollSuccess(e, bambuStatus('Finished', 100), T0 + 10_000 + C.CLOCK_MAX_GAP_MS + 90_000);
  assert.equal(e.lastCompleted, undefined, 'no figures at all: nothing sliced, nothing watched');
});

test('a job already printing on Khayt\'s first poll is not timed, even at 0%', () => {
  const T0 = 1_000_000;
  const e = run([
    [T0, bambuStatus('Printing', 0)],
    [T0 + 600_000, bambuStatus('Finished', 100)],
  ]);
  assert.equal(e.lastCompleted, undefined, 'Khayt never saw it start');
});

test('only a Bambu keeps a job clock', () => {
  const e = run([
    [1, { state: 'printing', progress: 0, filename: 'a.gcode', type: 'moonraker' }],
    [2, { state: 'printing', progress: 5, filename: 'a.gcode', type: 'moonraker' }],
  ]);
  assert.equal(e.jobClock, undefined);
});

test('the clock never reaches the saved completions', () => {
  const T0 = 1_000_000;
  const e = run([
    [T0, bambuStatus('Idle', 0)],
    [T0 + 10_000, bambuStatus('Printing', 0)],
    [T0 + 610_000, bambuStatus('Finished', 100)],
  ]);
  const saved = C.completionsToPersist({ M: e });
  assert.deepEqual(Object.keys(saved.M[0]).sort(), ['actuals', 'at', 'filename']);
  assert.equal(saved.M[0].actuals.durationS, 600);
});
