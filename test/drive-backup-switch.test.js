'use strict';

/**
 * Drive's "keep a copy of every new model" switch (gdrive.backUpNew, set on
 * the Mac's storage pane; absent means on) is honoured when the desktop is the
 * one importing. Tiering is not a backup and is unaffected.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

test('the mirror skips Drive only when its backup switch is explicitly off', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  const body = src.slice(src.indexOf('async function printLibMirrorFile('), src.indexOf('// ── Tiering: keeping the library bigger'));
  assert.match(body, /remote\.kind === 'gdrive'/, 'a bucket keeps its own switch');
  assert.match(body, /\.backUpNew === false/, 'absent means on');
  assert.match(body, /const s3 = driveBackupOff \? null : remote;/);
});
