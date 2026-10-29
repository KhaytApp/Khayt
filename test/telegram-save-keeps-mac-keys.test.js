'use strict';
// The desktop's Telegram form shows eight fields; the Mac stores more in the
// same block (notifyPrinterRunout, the print notices — opt-in since Mac #2078 —
// and noticeNames). Save replaced the whole block, so a desktop Save silently
// switched the Mac's notices off again.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

test('the Telegram Save writes over the stored block, not instead of it', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'settings.js'), 'utf8');
  const at = src.indexOf("el.querySelector('#btnSaveTgSettings')");
  assert.ok(at > 0);
  const body = src.slice(at, src.indexOf('saveAll();', at));
  assert.match(body, /settings\.telegram = \{\s*(\/\/[^\n]*\n\s*)*\.\.\.\(settings\.telegram \|\| \{\}\),/);
});
