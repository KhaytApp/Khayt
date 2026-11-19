'use strict';
/**
 * C8 (Prusa batch 1): test/fixtures/send-checks-vectors.json through
 * lib/send-checks.js sendChecks, the findings before a file goes to a
 * printer. The Mac and the phone run the same file. Plus the closed sets,
 * `blocks`, the header reader, and inputs that are not what they claim.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
for (const f of ['color-mix', 'loaded-colours', 'print-fit', 'printer-upload', 'gcode-parse', 'send-checks']) require('../lib/' + f + '.js');
const S = globalThis.KhaytSendChecks, G = globalThis.KhaytGcodeParse, LC = globalThis.KhaytLoadedColours;
const V = require('./fixtures/send-checks-vectors.json');

const run = (c) => {
  const f = Object.assign({}, c.file);
  if (f.headerText) f.header = G.parsePrinterHeader(f.headerText);
  const l = c.loaded;
  return S.sendChecks(f, c.machine, l ? (l.ptc ? LC.fromPrintTaskConfig(l.ptc) : l.loaded) : undefined);
};

for (const c of V.cases) test(c.why, () => assert.deepEqual(run(c), c.want));

test('every finding is from the closed sets, and the fixture reaches every code', () => {
  const seen = new Set();
  for (const c of V.cases) for (const x of run(c)) {
    assert.ok(S.CODES.includes(x.code), x.code);
    assert.ok(S.SEVERITIES.includes(x.severity), x.severity);
    seen.add(x.code);
  }
  assert.deepEqual([...seen].sort(), S.CODES.slice().sort());
});

test('blocks: only a block finding holds the send', () => {
  assert.equal(S.blocks(run(V.cases.find((c) => /bed-footprint/.test(c.why)))), true);
  assert.equal(S.blocks(run(V.cases.find((c) => /bed-rotate/.test(c.why)))), false);
  assert.equal(S.blocks(run(V.cases.find((c) => /head 2 has filament_exist/.test(c.why)))), false);
  assert.equal(S.blocks(null), false);
});

test('a U1 head with filament_exist:false or NONE is never a mismatch, whatever the file wants', () => {
  for (const c of V.cases.filter((x) => x.loaded && x.loaded.ptc)) {
    for (const x of run(c)) if (x.slot === 2 || x.slot === 4) assert.equal(x.code, 'head-not-reported', c.why);
  }
});

test('junk in, nothing thrown and nothing invented', () => {
  for (const [file, machine, loaded] of [[null, null, null], [{}, {}, {}], ['x', 7, 'y'], [{ filaments: 'nope', bounds: 'big' }, { bed: 'huge', toolheads: -1 }, [null, 3, {}]],
    [{ filaments: [{ slot: 0 }, { slot: 1.5 }, { slot: '1' }] }, { model: {} }, [{ slot: 0 }]]]) {
    assert.deepEqual(S.sendChecks(file, machine, loaded), [], JSON.stringify([file, machine, loaded]));
  }
});

test('parsePrinterHeader: Orca, PrusaSlicer, offsets, nothing, and a hostile outline', () => {
  assert.deepEqual(G.parsePrinterHeader('; printer_model = Snapmaker U1\n; printable_area = 0x0,270x0,270x270,0x270\n; printable_height = 270\n'),
    { printerModel: 'Snapmaker U1', bed: { x: 270, y: 270, z: 270 } });
  assert.deepEqual(G.parsePrinterHeader('G1\n; bed_shape = 0x-2,250x-2,250x210,0x210\n; max_print_height = 220\n; printer_model = MK4\n'),
    { printerModel: 'MK4', bed: { x: 250, y: 212, z: 220 } });
  assert.deepEqual(G.parsePrinterHeader('G28\n'), { printerModel: null, bed: null });
  const big = '; printable_area = ' + Array.from({ length: 200000 }, (_, i) => i + 'x' + i).join(',') + '\n';
  const t = Date.now();
  const r = G.parsePrinterHeader(big);
  assert.ok(Date.now() - t < 500, 'bounded');
  assert.ok(r.bed && r.bed.x <= 64, 'only the first 64 corners are read');
});
