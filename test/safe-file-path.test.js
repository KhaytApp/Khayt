'use strict';
// lib/safe-file-path.js: the folder and type checks in front of hub:open-path,
// hub:copy-file-to-vault and hub:printlib-copy-path look at where a file
// REALLY is. They compared the path as the window spelled it, so a symlink
// in an allowed folder could name anything.
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { realFileWithin, OPENABLE_EXTS, VAULT_EXTS } = require('../lib/safe-file-path');

let root, allowed, outside;
before(() => {
  root = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-safe-path-'));
  allowed = path.join(root, 'Downloads');
  outside = path.join(root, 'ssh');
  fs.mkdirSync(allowed); fs.mkdirSync(outside);
  fs.writeFileSync(path.join(allowed, 'invoice.pdf'), '%PDF');
  fs.writeFileSync(path.join(allowed, 'part.stl'), 'solid');
  fs.writeFileSync(path.join(allowed, 'run.command'), '#!/bin/sh');
  fs.writeFileSync(path.join(outside, 'id_ed25519'), 'KEY');
  fs.writeFileSync(path.join(outside, 'real.stl'), 'solid');
  fs.symlinkSync(path.join(outside, 'id_ed25519'), path.join(allowed, 'model.stl'));
  fs.symlinkSync(path.join(outside, 'real.stl'), path.join(allowed, 'linked.stl'));
  fs.symlinkSync(outside, path.join(allowed, 'dirlink'));
});
after(() => fs.rmSync(root, { recursive: true, force: true }));

const check = (p, exts, dirs = [allowed]) => realFileWithin(p, { dirs, exts, fs, path });

test('a file of an expected kind inside the folder passes, as its real path', () => {
  const r = check(path.join(allowed, 'invoice.pdf'), OPENABLE_EXTS);
  assert.equal(r.ok, true);
  assert.equal(r.real, fs.realpathSync(path.join(allowed, 'invoice.pdf')));
});

test('a symlink named like a print file that points at a key is refused', () => {
  assert.equal(check(path.join(allowed, 'model.stl'), VAULT_EXTS).ok, false);
});

test('a symlink to a print file outside the folder is refused for the vault', () => {
  const r = check(path.join(allowed, 'linked.stl'), VAULT_EXTS);
  assert.equal(r.ok, false);
  assert.match(r.error, /outside allowed directories/);
});

test('a path through a linked folder is checked where it lands', () => {
  assert.equal(check(path.join(allowed, 'dirlink', 'real.stl'), VAULT_EXTS).ok, false);
});

test('../ out of the folder is refused', () => {
  assert.equal(check(path.join(allowed, '..', 'ssh', 'real.stl'), VAULT_EXTS).ok, false);
});

test('a kind the app never opens is refused even inside the folder', () => {
  const r = check(path.join(allowed, 'run.command'), OPENABLE_EXTS);
  assert.equal(r.ok, false);
  assert.match(r.error, /not allowed/);
});

test('the folder itself, a missing file and an empty path are refused', () => {
  assert.equal(check(allowed, OPENABLE_EXTS).ok, false);
  assert.equal(check(path.join(allowed, 'nope.pdf'), OPENABLE_EXTS).ok, false);
  assert.equal(check('', OPENABLE_EXTS).ok, false);
});

test('with no folder list (the print library) only the real file\'s kind is checked', () => {
  const lib = (p) => realFileWithin(p, { exts: ['stl'], fs, path });
  assert.equal(lib(path.join(outside, 'real.stl')).ok, true, 'a model on a NAS or USB stick');
  assert.equal(lib(path.join(allowed, 'model.stl')).ok, false, 'a key behind an .stl name');
});

test('main.js routes all three handlers through it', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  for (const h of ['hub:open-path', 'hub:copy-file-to-vault', 'hub:printlib-copy-path']) {
    const body = src.slice(src.indexOf(`ipcMain.handle('${h}'`)).slice(0, 1500);
    assert.match(body, /SafeFilePath\.realFileWithin\(/, h);
  }
});
