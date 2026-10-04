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
  const body = b.slice(at, at + 9000);
  assert.match(body, /if \(formHasPendingPart\(\)\) \{/);
  assert.match(body, /totalBase \+= pendingBase;/);
  assert.match(body, /calcPendingNote/);
  for (const page of ['renderer/index.html', 'renderer/bedready.html']) assert.match(read(page), /id="calcPendingNote"/, page);
});

test('a pending part is "a weight or a time in the form", which addPart clears', () => {
  const b = read('renderer/build.js');
  assert.match(b, /function formHasPendingPart\(\) \{\n\s+return clampPositive\(\$\('#printWeight'\)\?\.value\) > 0 \|\| clampPositive\(\$\('#printTime'\)\?\.value\) > 0;/);
  const add = b.slice(b.indexOf('function addPart()'), b.indexOf('function addPart()') + 1500);
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
