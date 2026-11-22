/**
 * Clearing a model's photo on the desktop must say so to the Mac. The Mac
 * brings in pictures it finds in linked folders and skips a model whose
 * `userPhotoRemoved` is `true` (Shop+LinkedSort.swift); without it, a photo the
 * shop removed here came back on the next linked pass.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const pf = fs.readFileSync(path.join(ROOT, 'renderer/printfiles.js'), 'utf8');

test('clearing a photo marks it removed, and setting one unmarks it', () => {
  assert.match(pf, /if \(ph\.cleared\) \{ rec\.userPhoto = null; rec\.userPhotoRemoved = true; \}/);
  assert.match(pf, /rec\.userPhoto = ph\.stagedPhoto; if \(rec\.userPhotoRemoved\) rec\.userPhotoRemoved = false;/);
});

test('the Mac reads the flag as the boolean the desktop writes', () => {
  const mac = fs.readFileSync(path.join(ROOT, 'mac/KhaytCore/Sources/KhaytApp/Shop+LinkedSort.swift'), 'utf8');
  assert.match(mac, /case \.bool\(true\)\? = o\["userPhotoRemoved"\]/);
});
