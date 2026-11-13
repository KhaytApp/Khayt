'use strict';
/**
 * The colour families the library's Colour filter is made of
 * (lib/colour-family.js), and the file types beside them
 * (lib/model-file-type.js).
 *
 * Every named colour here is a decision somebody made — where gold stops
 * being orange, whether maroon is red or brown — pinned so that moving a
 * threshold to fix one colour shows what else it moved.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const C = require('../lib/colour-family.js');
const T = require('../lib/model-file-type.js');

test('the families, in menu order', () => {
  assert.deepEqual(C.FAMILIES,
    ['red', 'orange', 'yellow', 'green', 'blue', 'purple', 'pink', 'brown', 'black', 'grey', 'white']);
  assert.deepEqual(C.TOKENS, [...C.FAMILIES, 'multi', 'none']);
  // A swatch per family, and each swatch is in the family it stands for.
  for (const f of C.FAMILIES) assert.equal(C.familyOf(C.SWATCH[f]), f, `the ${f} swatch`);
});

test('the decided colours', () => {
  const decided = {
    '#D4AF37': 'yellow',  // gold
    '#0A2A50': 'blue',    // dark navy
    '#1A1A1E': 'black',   // near-black with a slight tint
    '#FAF7F0': 'white',   // near-white
    '#C8AD7F': 'brown',   // beige / tan
    '#C0C0C0': 'grey',    // silver
    '#0E8A7E': 'green',   // teal
    '#008080': 'green',   // teal, at exactly 180°
    '#00B7EB': 'blue',    // cyan
    '#FF00FF': 'purple',  // magenta — PICKED: purple
    '#F28C28': 'orange',  // orange filament
    '#F2A541': 'orange',  // amber
    '#808000': 'green',   // olive
    '#800000': 'red',     // maroon — PICKED: red
    '#FFDAB9': 'orange',  // skin / peach — PICKED: orange
  };
  for (const [hex, family] of Object.entries(decided)) assert.equal(C.familyOf(hex), family, hex);
});

test('the plain colours, and the ones a spool rack is full of', () => {
  const plain = {
    '#FF0000': 'red', '#00FF00': 'green', '#0000FF': 'blue', '#FFFF00': 'yellow',
    '#FFFFFF': 'white', '#000000': 'black', '#808080': 'grey', '#800080': 'purple',
    '#FF69B4': 'pink', '#FFB6C1': 'pink', '#B76E79': 'pink',            // hot, light, rose gold
    '#6F4E37': 'brown', '#964B00': 'brown', '#8B4513': 'brown', '#A0522D': 'brown',
    '#8A2BE2': 'purple', '#B57EDC': 'purple',
    '#DC143C': 'red', '#800020': 'red',                                  // crimson, burgundy
    '#32CD32': 'green', '#98FF98': 'green', '#40E0D0': 'green',          // lime, mint, turquoise
    '#87CEEB': 'blue', '#00008B': 'blue',
    '#333333': 'grey', '#D3D3D3': 'grey', '#708090': 'grey',             // slate is a grey
    '#EDE3D2': 'white', '#F5F5DC': 'white',                              // cream, beige-white
    '#FFDB58': 'yellow', '#CD7F32': 'orange',                            // mustard, bronze
  };
  for (const [hex, family] of Object.entries(plain)) assert.equal(C.familyOf(hex), family, hex);
});

test('every colour there is has a family', () => {
  for (let r = 0; r <= 255; r += 5) {
    for (let g = 0; g <= 255; g += 5) {
      for (let b = 0; b <= 255; b += 5) {
        assert.ok(C.FAMILIES.includes(C.familyOfRgb(r, g, b)), `${r},${g},${b}`);
      }
    }
  }
});

test('the ways a hex is written', () => {
  for (const hex of ['#F28C28', 'F28C28', '#f28c28', 'f28C28', '  #F28C28 ', '#F28C28FF', 'F28C2800']) {
    assert.equal(C.familyOf(hex), 'orange', JSON.stringify(hex));
  }
  assert.equal(C.familyOf('#F00'), 'red');
  assert.equal(C.familyOf('0f0'), 'green');
  assert.equal(C.familyOf('#00F8'), 'blue', 'a short form with an alpha');
  assert.deepEqual(C.parseHex('#0A2a50'), [10, 42, 80]);
  for (const bad of ['', '#', '#12', '#12345', '#1234567', '#GGGGGG', 'red', 'rgb(1,2,3)', '#F28C28FFF',
    null, undefined, 0xff0000, {}, [], true]) {
    assert.equal(C.familyOf(bad), null, JSON.stringify(bad));
  }
});

test('a model\'s families: each once, in menu order, from either shape', () => {
  const colors = [{ hex: '#FFFFFF', label: 'White', grams: 4 }, { hex: '#0A2A50' }, { hex: '#D92D20' },
    { hex: '#FF0000' }, { hex: '#00B7EB' }];
  assert.deepEqual(C.familiesOf(colors), ['red', 'blue', 'white']);
  assert.deepEqual(C.familiesOf(['fff', '#0A2A50', 'D92D20']), ['red', 'blue', 'white']);
  assert.deepEqual(C.familiesOf([{ hex: 'nope' }, null, 7, { label: 'Red' }, '#1A1A1E']), ['black']);
  for (const none of [undefined, null, [], '#FF0000', { hex: '#FF0000' }, 5]) {
    assert.deepEqual(C.familiesOf(none), [], JSON.stringify(none));
  }
});

test('the filter ids: every family, multi for two different ones, none honestly', () => {
  assert.deepEqual(C.tokensOf([{ hex: '#FF0000' }]), ['red']);
  assert.deepEqual(C.tokensOf([{ hex: '#FF0000' }, { hex: '#D92D20' }]), ['red'],
    'two reds are one colour, not multicolour');
  assert.deepEqual(C.tokensOf([{ hex: '#FFFFFF' }, { hex: '#FF0000' }, { hex: '#000000' }]),
    ['red', 'black', 'white', 'multi']);
  for (const none of [undefined, null, [], [{ hex: '' }], [{ label: 'Red' }], ['zzz']]) {
    assert.deepEqual(C.tokensOf(none), ['none'], JSON.stringify(none));
  }
  // One unreadable colour beside a readable one is not a second family.
  assert.deepEqual(C.tokensOf([{ hex: '#FF0000' }, { hex: '??' }]), ['red']);
});

test('file types: the fixed list', () => {
  assert.deepEqual(T.TYPES, ['3mf', 'stl', 'step', 'obj', 'gcode', 'other', 'nofile']);
});

test('file types: from the record\'s own extension', () => {
  const of = (sourceFile, rest) => T.typeOf({ id: 'PF-1', sourceFile, ...rest });
  assert.equal(of({ filename: 'a.3mf', ext: '3mf', kind: 'model' }), '3mf');
  assert.equal(of({ filename: 'a.stl', ext: 'stl', kind: 'model' }), 'stl');
  assert.equal(of({ filename: 'a.step', ext: 'step' }), 'step');
  assert.equal(of({ filename: 'a.stp', ext: 'STP' }), 'step');
  assert.equal(of({ filename: 'a.obj', ext: '.obj' }), 'obj');
  assert.equal(of({ filename: 'a.gcode', ext: 'gcode', kind: 'gcode' }), 'gcode');
  assert.equal(of({ filename: 'a.bgcode', ext: 'bgcode' }), 'gcode');
  assert.equal(of({ filename: 'plate.bin', ext: 'bin', kind: 'gcode' }), 'gcode', 'by its kind');
  assert.equal(of({ filename: 'plate_1.gcode.3mf', ext: '3mf', kind: 'model' }), 'gcode', 'a sliced plate');
  assert.equal(of({ filename: 'stored-name.3mf', originalName: 'Plate.GCODE.3MF', ext: '3mf' }), 'gcode');
  assert.equal(of({ filename: 'a.scad', ext: 'scad' }), 'other');
  assert.equal(of({ filename: 'a.zip', ext: 'zip' }), 'other');
  assert.equal(of({ filename: 'README', ext: '' }), 'other', 'a file with no extension is still a file');
  assert.equal(of({}), 'other');
});

test('file types: with no stated extension, from the name', () => {
  assert.equal(T.typeOf({ sourceFile: { filename: 'Dragon.v2.STL' } }), 'stl');
  assert.equal(T.typeOf({ sourceFile: { originalName: 'part.step' } }), 'step');
  // Linked in place: no sourceFile, the path says what it is.
  assert.equal(T.typeOf({ externalPath: '/Volumes/Models/benchy.3mf' }), '3mf');
  assert.equal(T.typeOf({ externalPath: 'C:\\Models\\benchy.obj' }), 'obj');
  assert.equal(T.typeOf({ externalPath: '/Downloads/Pack.zip', archiveMember: 'minis/knight.stl' }), 'stl',
    'a member of an archive is the member, not the archive');
  assert.equal(T.extOf('.hidden'), '');
  assert.equal(T.extOf('trailing.'), '');
});

test('file types: no file at all', () => {
  assert.equal(T.typeOf({ id: 'PF-web', name: 'Saved from a page', sourceUrl: 'https://example.com/m/1',
    savedFromWebAt: '2026-11-01T10:00:00.000Z', colors: [] }), 'nofile');
  assert.equal(T.typeOf({ sourceFile: null, externalPath: '' }), 'nofile');
  for (const junk of [null, undefined, 'x', 4, []]) assert.equal(T.typeOf(junk), 'nofile');
});

test('both load with no module system, as a page or JavaScriptCore loads them', () => {
  const fs = require('fs');
  const path = require('path');
  const vm = require('vm');
  for (const [file, name] of [['colour-family.js', 'KhaytColourFamily'], ['model-file-type.js', 'KhaytModelFileType']]) {
    const src = fs.readFileSync(path.join(__dirname, '..', 'lib', file), 'utf8');
    assert.ok(!/\brequire\s*\(/.test(src), `${file} must not require anything`);
    const sandbox = {};
    sandbox.globalThis = sandbox;
    vm.runInNewContext(src, sandbox);
    assert.equal(typeof sandbox[name], 'object', `${name} is on globalThis`);
  }
});
