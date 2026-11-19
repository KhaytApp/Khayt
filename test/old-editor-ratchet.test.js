'use strict';
/**
 * The old job editor (renderer/order-flows.js openOrderEditor) is retiring
 * (~/Khayt-proposals/electron-old-editor-retirement.md). Step 7 re-pointed
 * every entry point at the job page or the job sheet. This ratchet counts the
 * calls left, per file: a NEW caller fails it, and a caller removed must be
 * removed here too, so the list only shrinks. At step 8 (deletion, on Dev
 * Hub's OK) ALLOWED becomes {} and this reads "no caller exists".
 *
 * Counted by grep over the app's own sources, as the retirement was scoped
 * (calls, not the definition or the export).
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const ALLOWED = {
  // The sheet's "More…", the way to anything the sheet and page do not hold yet.
  'renderer/job-sheet.js': 1,
};

function files(dir) {
  const out = [];
  for (const e of fs.readdirSync(path.join(ROOT, dir), { withFileTypes: true })) {
    const rel = path.join(dir, e.name);
    if (e.isDirectory()) { if (e.name !== 'locales' && e.name !== 'vendor') out.push(...files(rel)); }
    else if (e.name.endsWith('.js')) out.push(rel);
  }
  return out;
}

test('no new caller of the old job editor: open the job page or the job sheet instead', () => {
  const found = {};
  for (const rel of files('renderer').concat(files('lib'), ['main.js'])) {
    const src = fs.readFileSync(path.join(ROOT, rel), 'utf8');
    const calls = (src.match(/\bopenOrderEditor\s*\(/g) || []).length
      - (src.match(/function\s+openOrderEditor\s*\(/g) || []).length;
    if (calls > 0) found[rel.split(path.sep).join('/')] = calls;
  }
  assert.deepEqual(found, ALLOWED,
    'callers of openOrderEditor changed: a new one should open the job page (openJobPage) or the job sheet (openJobSheet); a removed one is removed from ALLOWED');
});
