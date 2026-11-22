/**
 * Which filaments each PLATE uses, as opposed to which the file declares.
 *
 * `filament_colour` is file-wide. A multi-plate project therefore reports one palette for
 * everything in it, and the converter recommended the same spools for every plate — which
 * on a real 18-plate poster is wrong twice over. Its plates are different designs: four are
 * white/amber/green, five are red/blue/black. And file-wide it reads as six colours, so the
 * converter calls it a Full-Spectrum job, when 17 of its 18 plates fit four heads outright.
 *
 * Correctness against that file is measured directly (see the commit); what is pinned here
 * is the contract and the ways it is allowed to fail, since a converter helper that throws
 * takes the convert down with it.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { platePalettes, analyze, readMembers } = require('../lib/mf-convert');
const { writeZip } = require('../lib/zip-write');

const CT = '<?xml version="1.0" encoding="UTF-8"?>\n'
  + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
  + '<Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>';

const MODEL = '<?xml version="1.0" encoding="UTF-8"?>\n'
  + '<model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">'
  + '<resources><object id="1" type="model"><mesh><vertices>'
  + '<vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/><vertex x="0" y="10" z="0"/><vertex x="0" y="0" z="10"/>'
  + '</vertices><triangles>'
  + '<triangle v1="0" v2="1" v3="2"/><triangle v1="0" v2="2" v3="3"/>'
  + '<triangle v1="0" v2="3" v3="1"/><triangle v1="1" v2="3" v3="2"/>'
  + '</triangles></mesh></object></resources>'
  + '<build><item objectid="1" transform="1 0 0 0 1 0 0 0 1 0 0 0"/></build></model>';

const file = (extra) => writeZip([
  { name: '[Content_Types].xml', data: Buffer.from(CT, 'utf8') },
  { name: 'Metadata/project_settings.config', data: Buffer.from(JSON.stringify({ filament_colour: ['#FF0000', '#00FF00'] }), 'utf8') },
  { name: '3D/3dmodel.model', data: Buffer.from(MODEL, 'utf8') },
  ...(extra || []),
]);

test('a plateless file yields no plate palettes rather than a fake one', () => {
  const got = platePalettes(readMembers(file()));
  assert.ok(Array.isArray(got), 'always an array — callers iterate it');
  assert.equal(got.length, 0, 'inventing a plate would be worse than reporting none');
});

test('every entry describes a plate completely enough to act on', () => {
  for (const p of platePalettes(readMembers(file()))) {
    assert.equal(typeof p.index, 'number');
    assert.ok(Array.isArray(p.colorIndices) && Array.isArray(p.colors));
    assert.equal(typeof p.sampled, 'boolean',
      'a thinned mesh can miss a colour on very few faces; the caller has to be able to know');
  }
});

test('analyze carries it, so the panel need not re-read the file', () => {
  const a = analyze(file());
  assert.ok(Array.isArray(a.platePalettes), 'analyze should expose platePalettes');
});

test('it never throws, whatever it is handed', () => {
  for (const [why, arg] of [
    ['nothing', undefined],
    ['an empty member list', []],
    ['members that are not members', [{ name: 'x', data: Buffer.from('not a model') }]],
    ['a non-3MF buffer', readMembers(Buffer.from('plainly not a zip'))],
  ]) {
    assert.doesNotThrow(() => platePalettes(arg), why + ' should not throw');
    assert.ok(Array.isArray(platePalettes(arg)), why + ' should still give an array');
  }
});
