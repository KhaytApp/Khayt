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
  // Nor "خيط السحابي" ("the cloud Khayt"): one name, سحابة خيط, with feminine verbs.
  assert.deepEqual(src.split('\n').filter((l) => /خَ?يط السحابي/.test(l)).map((l) => l.trim().split('"')[1]), []);
  assert.match(src, /"set\.pane_cloud": "سحابة خيط"/);
});

/**
 * And the app itself is خيط in Arabic letters (Turki, Nov 10): "تطبيق خيط"
 * where خيط alone could read as "filament". Latin "Khayt" stays only where
 * it is not a word the shop reads as the brand: the bilingual lockup in the
 * window title, HTTP header names, a real folder path, and the app's name
 * as Google's account page lists it.
 */
test('the Arabic desktop writes the brand in Arabic letters, except where Latin is the thing itself', () => {
  const src = fs.readFileSync(path.join(__dirname, '../renderer/locales/ar.js'), 'utf8');
  const latin = src.split('\n').map((l) => l.match(/^\s*"([^"]+)": ".*Khayt/)).filter(Boolean).map((m) => m[1]);
  assert.deepEqual(latin.sort(), ['app.title', 'ewh.hint', 'set.icloud_hint', 'set.plib_gd_disconnected']);
  assert.match(src, /"app\.title": "Khayt · خيط"/);
  assert.doesNotMatch(src, /Khayt Cloud/);
});
