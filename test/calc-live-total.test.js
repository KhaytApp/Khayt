'use strict';

/**
 * The calculator's project total follows the part in the form, and nothing
 * that saves the build can drop that part (a tester's report, via the Mac lane).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const read = (f) => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');

test('the total counts the pending part, and says so', () => {
  const b = read('renderer/build.js');
  const at = b.indexOf('function updateGrandTotal');
  // The whole function: a fixed 9000-character window sat 60 characters short
  // of the note on main, so any addition earlier in the function failed it.
  const end = b.indexOf('\nfunction ', at + 10);
  const body = b.slice(at, end > at ? end : at + 20000);
  assert.match(body, /if \(formHasPendingPart\(\)\) \{/);
  assert.match(body, /totalBase \+= pendingBase;/);
  assert.match(body, /calcPendingNote/);
  for (const page of ['renderer/index.html', 'renderer/bedready.html']) assert.match(read(page), /id="calcPendingNote"/, page);
});

test('a pending part is "a weight or a time in the form", which addPart clears', () => {
  const b = read('renderer/build.js');
  assert.match(b, /function formHasPendingPart\(\) \{\n\s+return clampPositive\(\$\('#printWeight'\)\?\.value\) > 0 \|\| clampPositive\(\$\('#printTime'\)\?\.value\) > 0;/);
  // The whole function, not a fixed 1500 characters: lines added near its top
  // (the once-costs mark, #2581) pushed the clearing out of the window.
  const addAt = b.indexOf('function addPart()');
  const add = b.slice(addAt, b.indexOf('\nfunction ', addAt + 10));
  assert.match(add, /\$\('#printWeight'\)\.value = '';/);
  assert.match(add, /\$\('#printTime'\)\.value = '';/);
});

test('creating a job, a Bed Ready job or a template keeps the part in the form', () => {
  assert.match(read('renderer/order-flows.js'), /if \(currentBuild\.length === 0 \|\| formHasPendingPart\(\)\) \{/);
  assert.match(read('renderer/bedready-jobs.js'), /if \(currentBuild\.length === 0 \|\| pending\) \{/);
  const b = read('renderer/build.js');
  const tpl = b.slice(b.indexOf('function saveQuoteTemplate'), b.indexOf('function saveQuoteTemplate') + 300);
  assert.match(tpl, /if \(formHasPendingPart\(\)\) addPart\(\);/);
});
