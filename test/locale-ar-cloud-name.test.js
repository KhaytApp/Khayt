'use strict';
/**
 * Khayt Cloud is "سحابة خيط" in Arabic (Turki, Nov 2026), the Mac's word since
 * beta.32. The desktop said "خَيط كلاود" or "خيط كلاود" in 17 strings; one transliteration
 * left behind makes the same product two names in one app.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

test('the Arabic desktop never calls Khayt Cloud "كلاود"', () => {
  const src = fs.readFileSync(path.join(__dirname, '../renderer/locales/ar.js'), 'utf8');
  const hits = src.split('\n').filter((l) => l.includes('كلاود')).map((l) => l.trim().split('"')[1]);
  assert.deepEqual(hits, []);
  assert.match(src, /"set\.pane_cloud": "سحابة خيط"/);
});
