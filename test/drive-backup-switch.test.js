'use strict';

/**
 * Each remote's "keep a copy of every new model" switch (s3.backUpNew,
 * gdrive.backUpNew, set on the Mac's storage pane; absent means on) is
 * honoured when the desktop is the one importing. Tiering is not a backup and
 * is unaffected.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

test('the mirror skips the in-use remote only when its backup switch is explicitly off', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  const body = src.slice(src.indexOf('async function printLibMirrorFile('), src.indexOf('// ── Tiering: keeping the library bigger'));
  assert.match(body, /\[remote\.kind\]/, 'each remote reads its own switch: s3.backUpNew, gdrive.backUpNew');
  assert.match(body, /\.backUpNew === false/, 'absent means on');
  assert.match(body, /const s3 = backupOff \? null : remote;/);
});

test('saving the bucket form keeps fields it does not show', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'settings.js'), 'utf8');
  const body = src.slice(src.indexOf('settings.printLibrary = Object.assign({}, settings.printLibrary, {\n    s3: {'));
  assert.match(body.slice(0, 200), /s3: \{\n\s+\.\.\.cur,/, 's3.backUpNew survives a desktop save');
});
