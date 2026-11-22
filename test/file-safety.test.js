'use strict';

/**
 * Four places the desktop destroyed a shop's file without meaning to, found by
 * the Mac session's file-safety scan (2026-09-24) and each verified against
 * this code before it was changed.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

const mainJs = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
const bodyOf = (marker, len) => { const at = mainJs.indexOf(marker); assert.ok(at >= 0, marker); return mainJs.slice(at, at + len); };

test('ZATCA: generating a new key keeps the old one first', async () => {
  // The key a shop's CSID is bound to. Replaced with no copy, every invoice
  // after it fails ZATCA's signature check until the shop onboards again.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zatca-'));
  const handlers = {};
  const { registerZatcaCrypto } = require('../lib/zatca-crypto');
  registerZatcaCrypto({
    app: { getPath: () => dir }, fs, crypto,
    ipcMain: { handle: (name, fn) => { handlers[name] = fn; } },
    encryptStoreField: (s) => 'enc:' + s, decryptStoreField: (s) => s.slice(4),
  });
  const keyFile = path.join(dir, 'zatca-keypair.enc');

  assert.equal((await handlers['hub:zatca-gen-keypair']()).ok, true);
  const first = fs.readFileSync(keyFile, 'utf8');
  assert.deepEqual(fs.readdirSync(dir).filter((f) => f.endsWith('.bak')), [], 'nothing to keep on a first key');

  assert.equal((await handlers['hub:zatca-gen-keypair']()).ok, true);
  const kept = fs.readdirSync(dir).filter((f) => /^zatca-keypair\..+\.enc\.bak$/.test(f));
  assert.equal(kept.length, 1, 'the replaced key must be kept beside the new one');
  assert.equal(fs.readFileSync(path.join(dir, kept[0]), 'utf8'), first, 'and kept byte for byte');
  assert.notEqual(fs.readFileSync(keyFile, 'utf8'), first, 'the new key is the one in use');
});

test('library delete moves to the Trash and never falls back to a permanent delete', () => {
  const body = bodyOf("ipcMain.handle('hub:printlib-delete'", 2200);
  assert.match(body, /shell\.trashItem\(p\)/, 'the model is not sent to the Trash');
  assert.doesNotMatch(body, /\.unlink\(|\.rm\(|rmSync|unlinkSync/, 'a permanent delete is still reachable');
});

test('the daily backup is named by the local day the renderer compares against', () => {
  const body = bodyOf("ipcMain.handle('hub:write-backup'", 900);
  assert.match(body, /safeNames\.localDayName\(\)/);
  assert.doesNotMatch(body, /toISOString\(\)\.split\('T'\)/, 'still named by the UTC day');
});

test('a second file of the same name joins an order instead of replacing the first', () => {
  const body = bodyOf("ipcMain.handle('hub:copy-file-to-vault'", 1600);
  assert.match(body, /safeNames\.uniqueName\(/);
  assert.match(body, /COPYFILE_EXCL/, 'the copy itself must refuse to overwrite');
});
