'use strict';
/**
 * "Split into plates" and "keep the prime tower" on the desktop converter.
 *
 * lib/plate-split.js and mf-convert's vlhGuard are tested in plate-split.test.js; this
 * is the desktop's wiring around them: the worker job that writes one file per plate,
 * the analysis flag that decides whether the tower choice is shown, and the IPC and
 * renderer paths that carry both options (a correct module with no caller is the bug
 * this repo keeps having).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
require('./helpers/no-installed-slicer');

const jobs = require('../lib/mf-jobs');
const mf = require('../lib/mf-convert');
const plates = require('../lib/plates');
const { buildMultiPlate3mf } = require('./helpers/multi-plate-3mf');

const root = path.join(__dirname, '..');
const read = (f) => fs.readFileSync(path.join(root, f), 'utf8');

test('the worker job writes one file per plate into the temp folder, named after the plate', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-split-test-'));
  try {
    const src = path.join(dir, 'poster.3mf');
    fs.writeFileSync(src, buildMultiPlate3mf());
    const out = fs.mkdtempSync(path.join(dir, 'out-'));
    const r = await jobs.run('splitPlates', { src, maxBytes: 50_000_000, tmpDir: out, sourceName: 'poster.3mf', opts: { targetId: 'snapmaker-u1' } });
    assert.equal(r.ok, true, r.error);
    assert.equal(r.files.length, 3);
    for (const f of r.files) {
      assert.equal(f.ok, true, `plate ${f.index}: ${f.error}`);
      assert.equal(f.fileName, `poster-plate${f.index}.3mf`);
      assert.equal(path.dirname(f.tmpPath), out);
      assert.equal(f.buffer, undefined, 'no buffer travels back over the pipe');
      assert.ok(fs.statSync(f.tmpPath).size === f.size && f.size > 0);
      assert.ok(mf.analyze(fs.readFileSync(f.tmpPath)).ok);
    }
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('a one-plate file is refused by the job, not half-written', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-split-test-'));
  try {
    const src = path.join(dir, 'sign.3mf');
    fs.writeFileSync(src, plates.extractPlate(buildMultiPlate3mf(), 3).buffer);
    const r = await jobs.run('splitPlates', { src, maxBytes: 50_000_000, tmpDir: dir, opts: { targetId: 'snapmaker-u1' } });
    assert.equal(r.ok, false);
    assert.equal(r.code, 'single-plate');
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('the analysis says whether the file has variable layer height', () => {
  const zw = require('../lib/zip-write');
  const withVlh = buildMultiPlate3mf();
  assert.equal(mf.analyze(withVlh).variableLayerHeight, true);
  const members = plates.readMembers(withVlh).filter((m) => !/layer_(heights_profile\.txt|config_ranges\.xml)$/i.test(m.name));
  const without = zw.writeZip(members.map((m) => (m.src || m.raw ? { name: m.name, raw: m.src || m.raw } : { name: m.name, data: m.data })));
  assert.equal(mf.analyze(without).variableLayerHeight, false);
});

test('main asks for the folder first, never overwrites, and passes only a known vlhGuard', () => {
  const main = read('main.js');
  const h = main.slice(main.indexOf("ipcMain.handle('hub:mf-split-plates'"));
  const body = h.slice(0, h.indexOf('\n});') + 4);
  assert.ok(body.indexOf('showOpenDialog') > 0 && body.indexOf('showOpenDialog') < body.indexOf("mfRun('splitPlates'"), 'folder before the work');
  assert.match(body, /mfReadAllowed\(srcPath\)/);
  assert.match(body, /fs\.existsSync\(dest\)/, 'an existing file gets a number, not overwritten');
  assert.match(body, /finally \{ if \(tmpDir\)/, 'the temp folder is cleared');
  assert.match(main, /function mfVlhGuard\(v\) \{ return v === 'keep-prime-tower' \|\| v === 'keep-layers' \? v : undefined; \}/);
  const convert = main.slice(main.indexOf("ipcMain.handle('hub:mf-convert'"));
  assert.match(convert.slice(0, convert.indexOf('\n});')), /vlhGuard: mfVlhGuard\(vlhGuard\)/);
  assert.match(read('preload.js'), /mfSplitPlates: \(opts\) +=> ipcRenderer\.invoke\('hub:mf-split-plates', opts\)/);
});

test('the converter sends the split and the tower choice, both off until ticked', () => {
  const c = read('renderer/converter.js');
  assert.match(c, /let platesList = null, splitOn = false, keepTower = false;/);
  assert.match(c, /hub\(\)\.mfSplitPlates\(\{ path: src\.path, targetId, targetProfile, process, vlhGuard \}\)/);
  assert.match(c, /\.\.\.\(vlhGuard \? \{ vlhGuard \} : \{\}\) \}\);/, 'a normal convert carries vlhGuard');
  assert.match(c, /a\.variableLayerHeight && retargets\(\) && targetIsSnapmaker\(\) \? 'keep-prime-tower' : null/);
  for (const loc of ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh']) {
    const L = read(`renderer/locales/${loc}.js`);
    for (const k of ['conv.split_plates', 'conv.split_note', 'conv.split_fits', 'conv.split_working', 'conv.split_done', 'conv.split_failed_one', 'conv.keep_tower', 'conv.keep_tower_note']) {
      assert.ok(L.includes(`"${k}":`), `${loc} has ${k}`);
    }
  }
});

test("the renderer's fit rule agrees with lib/plates.js platesFitSlots", () => {
  // The renderer cannot load lib/plates.js, so it carries the rule; run its text against the lib's.
  const c = read('renderer/converter.js');
  const src = c.slice(c.indexOf('const platesFit = (slots) => {'), c.indexOf('// While splitting'));
  // eslint-disable-next-line no-new-func
  const make = new Function('platesListIn', `let platesList = platesListIn; ${src}; return platesFit;`);
  const cases = [
    [[[0, 1], [2, 3]], 2], [[[0, 1], [2, 3]], 4], [[[0, 1, 2], [3]], 2], [[[0]], 1],
    [[[0, 1], [1, 2], [3, 4]], 2], [[[], [0, 1, 2]], 2], [[[0, 1], [2]], 0],
  ];
  for (const [per, slots] of cases) {
    const list = per.map((colorIndices) => ({ colorIndices }));
    assert.equal(make(list)(slots), plates.platesFitSlots(list, slots) != null, JSON.stringify([per, slots]));
  }
});
