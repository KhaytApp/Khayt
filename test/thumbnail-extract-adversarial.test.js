'use strict';
/**
 * A crafted 3MF or G-code cannot freeze the app through lib/thumbnail-extract.js.
 *
 * beta.38 review (Nov 16): four patterns were super-linear on text a file
 * controls, and the Mac runs them on the shop's own engine at import and on
 * every launch's colour re-read:
 *   usedSlots' extruder match    `<metadata key="extruder" ` × n, no `>`: CUBIC (25 s / 50 KB)
 *   the slice's filament tags    `<filament …` × n, no `>`:          quadratic (12 s / 0.7 MB)
 *   the slice's change count     `filament change ` × n, no digit:  quadratic (2.9 s / 0.3 MB)
 *   G-code thumbnails            `; thumbnail begin 1x1 1` × n, no end: quadratic (2.3 s / 0.5 MB)
 * Each now scans linearly. Pinned: 50 KB in under 50 ms, and 8 MB (the size a
 * config member is read to) in well under a second and no more than about
 * linearly slower than 1 MB.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const T = require('../lib/thumbnail-extract.js');

const repeatTo = (unit, bytes) => unit.repeat(Math.ceil(bytes / unit.length));
const ms = (f) => { const t = process.hrtime.bigint(); f(); return Number(process.hrtime.bigint() - t) / 1e6; };

const CASES = {
  'usedSlots: <metadata key="extruder" with no >': (b) => () =>
    T.usedSlots({ modelSettings: '<config><object id="1">' + repeatTo('<metadata key="extruder" ', b) }),
  'slice: <filament with no >': (b) => () =>
    T.colorsFromConfigs({ sliceInfo: '<config>' + repeatTo('<filament id="1" color="#111111" ', b) }),
  'slice: a change count with no digit': (b) => () =>
    T.colorsFromConfigs({ sliceInfo: '<filament id="1" color="#111111" used_g="1"/>' + repeatTo('filament change ', b) }),
  'G-code: thumbnail begins with no end': (b) => () =>
    T.extractGcodeThumbnail(repeatTo('; thumbnail begin 1x1 1\n', b)),
};

for (const [name, make] of Object.entries(CASES)) {
  test(`${name}: 50 KB under 50 ms`, () => {
    const t = ms(make(50 * 1024));
    assert.ok(t < 50, `${t.toFixed(1)} ms`);
  });
  test(`${name}: 8 MB stays linear`, () => {
    const one = Math.max(ms(make(1 << 20)), 1);
    const eight = ms(make(8 << 20));
    assert.ok(eight < 1000, `${eight.toFixed(1)} ms for 8 MB`);
    // Eight times the text, and room for a busy machine: never the 64× of
    // quadratic or the 512× of cubic.
    assert.ok(eight < one * 8 * 4 + 20, `${eight.toFixed(1)} ms for 8 MB against ${one.toFixed(1)} ms for 1 MB`);
  });
}

test('the answers did not change', () => {
  const settings = '<config><object id="1"><metadata key="name" value="a"/><metadata key="extruder" value="4"/>' +
    '<part id="1"><metadata key="extruder" value="0"/></part><part id="2"><metadata key="extruder" value="2"/></part></object>' +
    '<object id="2"><metadata key="extruders" value="7"/></object></config>';
  assert.deepEqual(T.usedSlots({ modelSettings: settings }), [1, 2, 4], '0 inherits 4; a key that is not "extruder" is not one');
  const slice = '<config><plate><filament id="1" color="#111111" used_g="4.2"/><filaments color="#999999"/>' +
    '<filament id="2" color="#222222" used_g="0"/><filament id="3" colour="#333333" used_g="1.5"/></plate>' +
    '<metadata key="filament_changes" value="7"/></config>';
  const r = T.colorsFromConfigs({ sliceInfo: slice });
  assert.deepEqual(r.colors.map((c) => c.hex), ['#111111', '#333333'], '<filaments> is not a <filament>; 0 g is dropped');
  assert.equal(r.swapCount, 7, 'the first count after the first mention');
  const png = Buffer.from('png!').toString('base64');
  const gcode = `; thumbnail begin 2x2 ${png.length}\n; ${png}\n; thumbnail end\n` +
    `; thumbnail begin 9x9 3\n; not base64 !\n; thumbnail end\n; thumbnail begin 3x3 4\n; QUJD\n; thumbnail end\n; thumbnail begin 50x50 1\n`;
  assert.deepEqual(T.extractGcodeThumbnail(gcode), { pngBase64: 'QUJD', width: 3, height: 3 }, 'largest valid one; a begin with no end is not one');
});
