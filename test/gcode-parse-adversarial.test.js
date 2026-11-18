'use strict';
/**
 * A crafted G-code cannot freeze the app through lib/gcode-parse.js.
 *
 * beta.40 security review (Nov 17): `/estimated printing time[^=\n\r]*=…/i`
 * rescanned to the line's end from every occurrence of the phrase, so one
 * long line of it with no "=" was quadratic (800 KB: 13 s; 32 MB: hours).
 * The Mac's intake quote runs it on a file a STRANGER sends. It is now one
 * forward pass, and parseGcodeText reads only a large file's first and last
 * half megabyte. Pinned: every metadata key repeated on one line with no
 * separator stays under 50 ms at 50 KB and linear to 8 MB, through both the
 * direct parsers and parseGcodeText; and the new scan finds exactly what the
 * old pattern found, on generated text.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const G = require('../lib/gcode-parse.js');

const repeatTo = (unit, bytes) => unit.repeat(Math.ceil(bytes / unit.length));
const ms = (f) => { const t = process.hrtime.bigint(); f(); return Number(process.hrtime.bigint() - t) / 1e6; };

const UNITS = ['estimated printing time (normal mode) ', 'estimated printing time ', 'total estimated time ',
  'total filament used [g] ', 'filament used [g] ', 'filament used [cm3] ', 'total filament cost ',
  'filament_type ', '; filament_colour ', 'FILAMENT_WEIGHT ', '; TIME'];
const CASES = {};
for (const u of UNITS) {
  CASES[`parseGcodeText: ${JSON.stringify(u)} × n, no separator`] = (b) => () => G.parseGcodeText(repeatTo(u, b));
}
// The marker the head runs to, almost there n times and never whole.
CASES['parseGcodeText: "; EXECUTABLE_BLOCK_STAR" × n, the marker never whole'] = (b) => () => G.parseGcodeText(repeatTo('; EXECUTABLE_BLOCK_STAR', b));
// The direct parser, past parseGcodeText's half-megabyte edges.
CASES['parsePrintTimeMins: the phrase × n, no "="'] = (b) => () => G.parsePrintTimeMins(repeatTo('estimated printing time ', b));
CASES['parsePrintTimeMins: "=" then a long run of spaces'] = (b) => () => G.parsePrintTimeMins('estimated printing time =' + repeatTo(' ', b));

for (const [name, make] of Object.entries(CASES)) {
  test(`${name}: 50 KB under 50 ms`, () => {
    const t = ms(make(50 * 1024));
    assert.ok(t < 50, `${t.toFixed(1)} ms`);
  });
  test(`${name}: 8 MB stays linear`, () => {
    const one = Math.max(ms(make(1 << 20)), 1);
    const eight = ms(make(8 << 20));
    assert.ok(eight < 1500, `${eight.toFixed(0)} ms`);
    assert.ok(eight < one * 8 * 4 + 50, `1 MB ${one.toFixed(1)} ms, 8 MB ${eight.toFixed(1)} ms`);
  });
}

test('the scan finds what the old pattern found (generated text)', () => {
  const OLD = /estimated printing time[^=\n\r]*=\s*(?:(\d+)\s*d)?\s*(?:(\d+)\s*h)?\s*(?:(\d+)\s*m)?\s*(?:(\d+)\s*s)?/i;
  const bits = ['estimated printing time', 'Estimated Printing Time', ' (normal mode)', ' (silent mode)', ' = ', '=', ' ',
    '\n', '\r\n', '1d ', '2h ', '3m ', '4s', '12h', 'x', ';', ': ', '5m 6s', 'total estimated time: 1h'];
  let seed = 42;
  const rnd = (n) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n; };
  for (let k = 0; k < 4000; k++) {
    let s = '';
    for (let j = rnd(12); j >= 0; j--) s += bits[rnd(bits.length)];
    const m = OLD.exec(s);
    const want = m && (m[1] || m[2] || m[3] || m[4])
      ? Math.round(((+(m[1] || 0)) * 86400 + (+(m[2] || 0)) * 3600 + (+(m[3] || 0)) * 60 + (+(m[4] || 0))) / 60) : undefined;
    const got = G.parsePrintTimeMins(s);
    if (want !== undefined) assert.equal(got, want, JSON.stringify(s));
    else assert.ok(got === null || /total estimated time|;\s*TIME/i.test(s), JSON.stringify(s));
  }
});

test('a large file is read at its edges: head (Bambu, Cura) and footer (Prusa, Orca) both found', () => {
  const head = '; total estimated time: 1h 2m 3s\n; filament_type = PETG\n';
  const foot = '\n; filament used [g] = 12.5\n; filament used [cm3] = 10\n';
  const moves = repeatTo('G1 X1 Y1 E0.1\n', 3 << 20);
  const r = G.parseGcodeText(head + moves + foot);
  assert.equal(r.printTimeMins, 62);
  assert.equal(r.filamentGrams, 12.5);
  assert.equal(r.filamentType, 'PETG');
  // Something only in the middle of a large file is not read.
  const mid = G.parseGcodeText(moves + '; filament used [g] = 9\n' + moves);
  assert.equal(mid.filamentGrams, null);
});

test('characters whose lowercase is longer do not shift the reading (re-review, Nov 17)', () => {
  // 'İ' lowercases to two characters, 'ẞ' and final 'Σ' change too; a Turkish
  // or German object name in PrusaSlicer's footer comes before the summary.
  for (const pre of ['İ', 'İİ', 'İİİ', 'İİİİİİİİİİ', 'ẞẞ', 'ΣΣ', 'ΌΣΟΣ ', 'İẞΣ'.repeat(50)]) {
    const text = `; object name = ${pre}\n; estimated printing time (normal mode) = 12h 3m\n`;
    assert.equal(G.parsePrintTimeMins(text), 723, JSON.stringify(pre));
    assert.equal(G.parseGcodeText(text).printTimeMins, 723, JSON.stringify(pre));
  }
});

test('a Bambu config block pushed past half a megabyte by large thumbnails is still read (head runs to EXECUTABLE_BLOCK_START)', () => {
  const head = '; HEADER_BLOCK_START\n; total estimated time: 1h 2m 3s\n; HEADER_BLOCK_END\n';
  const thumbs = '; THUMBNAIL_BLOCK_START\n' + repeatTo('; iVBORw0KGgoAAAANSUhEUgAAAgAAAAIACAYAAAD0eNT6AAAgAElEQVR4nOy9\n', 900 * 1024) + '; THUMBNAIL_BLOCK_END\n';
  const config = '; CONFIG_BLOCK_START\n; filament_type = PETG;PLA\n; filament_colour = #00AE42;#FFFFFF\n; CONFIG_BLOCK_END\n';
  const moves = '; EXECUTABLE_BLOCK_START\n' + repeatTo('G1 X1 Y1 E0.1\n', 3 << 20);
  const r = G.parseGcodeText(head + thumbs + config + moves);
  assert.equal(r.filamentType, 'PETG');
  assert.equal(r.printTimeMins, 62);
  // Without the marker the head is half a megabyte, as before.
  assert.equal(G.parseGcodeText(head + thumbs + config + moves.replace('; EXECUTABLE_BLOCK_START\n', '')).filamentType, null);
});

test('a marker past 8 MB is not followed: the head stays bounded', () => {
  const t = repeatTo('; x\n', 9 << 20) + '; EXECUTABLE_BLOCK_START\n; filament_type = ABS\n' + repeatTo('G1 X1\n', 2 << 20);
  const ms0 = Date.now(); const r = G.parseGcodeText(t);
  assert.equal(r.filamentType, null);
  assert.ok(Date.now() - ms0 < 2000);
});

test('a 32 MB file with no EXECUTABLE_BLOCK_START reads in well under a second', () => {
  const t = repeatTo('G1 X1 Y1 E0.1\n', 32 << 20);
  const took = ms(() => G.parseGcodeText(t));
  assert.ok(took < 1000, `${took.toFixed(0)} ms`);
});
