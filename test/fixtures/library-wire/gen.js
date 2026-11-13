// The phone's Library filter wire, as fixtures both sides read.
//
// `GET /api/library` is answered by lib/lan-library.js `list` (and natively
// by the Mac), and the iPhone filters its own copies of the library by the
// same rule. This writes one small library and the answers `list` gives for a
// set of cases, so the phone's tests can read the SAME files and the two
// cannot drift (the fixture library and cases are the iPhone lane's, Nov 2026;
// they are how the menu-scope fault was found).
//
// Run `node test/fixtures/library-wire/gen.js` after changing the rule.
// test/lan-library.test.js fails while answers.json is stale.
'use strict';
const path = require('path');
const fs = require('fs');
const LanLibrary = require(path.resolve(__dirname, '../../../lib/lan-library.js'));

const files = [
  { id: 'm1', name: 'Red cup', folder: 'Home', sourceFile: { filename: 'cup.3mf' }, colors: [{ hex: '#D93B3B' }] },
  { id: 'm2', name: 'Red-white flag', folder: 'Home', sourceFile: { filename: 'flag.3mf' }, colors: [{ hex: '#D93B3B' }, { hex: '#FFFFFF' }] },
  { id: 'm3', name: 'Lantern', folder: 'Home/Lighting', sourceFile: { filename: 'lantern.3mf' }, colors: [{ hex: '#2EA65A' }] },
  { id: 'm4', name: 'Bracket', folder: 'Parts', sourceFile: { filename: 'bracket.stl' } },
  { id: 'm5', name: 'Gear', folder: 'Parts', sourceFile: { filename: 'gear.step' }, colors: [{ hex: '#111111' }] },
  { id: 'm6', name: 'Plate job', folder: 'Parts/Jobs', sourceFile: { filename: 'plate.gcode.3mf' }, colors: [{ hex: '#2F6DB5' }, { hex: '#111111' }] },
  { id: 'm7', name: 'Web idea', folder: '', colors: [] },
  { id: 'm8', name: 'Grey vase', folder: '', sourceFile: { filename: 'vase.obj' }, colors: [{ hex: '#8C9196' }] },
  { id: 'm9', name: 'Zip member', folder: 'Parts', archiveMember: 'pack.zip/clip.stl' },
  { id: 'm10', name: 'Gold medal', folder: 'Gifts', sourceFile: { filename: 'medal.3mf' }, colors: [{ hex: '#D4AF37' }] },
  { id: 'm11', name: 'Brown box', folder: 'Gifts', sourceFile: { filename: 'box.3mf' }, colors: [{ hex: '#6B4226' }] },
  { id: 'm12', name: 'Pink tag', folder: 'Gifts', sourceFile: { filename: 'tag.ply' }, colors: [{ hex: '#EA7FB3' }] },
];
const cases = [
  { name: 'top-none', folder: '' },
  { name: 'top-red', folder: '', colour: 'red' },
  { name: 'top-green', folder: '', colour: 'green' },
  { name: 'top-multi', folder: '', colour: 'multi' },
  { name: 'top-none-colour', folder: '', colour: 'none' },
  { name: 'top-3mf', folder: '', type: '3mf' },
  { name: 'top-red-3mf', folder: '', colour: 'red,black', type: '3mf,gcode' },
  { name: 'home-green', folder: 'Home', colour: 'green' },
  { name: 'parts-stl', folder: 'Parts', type: 'stl' },
  { name: 'parts-black', folder: 'Parts', colour: 'black' },
  { name: 'search-red', q: 'red', colour: 'red' },
  { name: 'nofile', folder: '', type: 'nofile' },
  { name: 'unknown-keys', folder: '', colour: 'teal', type: 'dwg' },
];

/** The answers, as written to answers.json. */
function answers() {
  const out = {};
  for (const c of cases) out[c.name] = { opts: c, answer: LanLibrary.list(files, Object.assign({ limit: 200 }, c)) };
  return out;
}

if (require.main === module) {
  fs.writeFileSync(path.join(__dirname, 'printFiles.json'), JSON.stringify(files, null, 1) + '\n');
  fs.writeFileSync(path.join(__dirname, 'answers.json'), JSON.stringify(answers(), null, 1) + '\n');
  console.log('cases', cases.length);
}
module.exports = { files, cases, answers };
