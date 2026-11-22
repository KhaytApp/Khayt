'use strict';

/**
 * The desktop's Storefront dialog: "On store" per product, and a look at the
 * listings before they go public. The rules are lib/storefront-catalog.js's
 * (#1614, shared with the Mac); this pins that the dialog uses them.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'settings.js'), 'utf8');
const dialog = src.slice(src.indexOf('async function openStorefrontModal()'), src.indexOf("modal.querySelector('#storeUnpublish')"));

test('a hidden product is still a row, so it can be shown again from this computer', () => {
  assert.match(dialog, /const pubProducts = SC\.publishable\(products, settings, sfLang, \{ includeHidden: true \}\)/);
});

test('"On store" writes storefrontHidden onto the product, removing it when shown', () => {
  assert.match(dialog, /class="sfShow"[^>]*\$\{p\.storefrontHidden \? '' : 'checked'\}/);
  assert.match(dialog, /if \(inp\.checked\) delete p\.storefrontHidden; else p\.storefrontHidden = true;/);
});

test('the listings are reviewed after the form is read and before anything is built', () => {
  const publish = dialog.slice(dialog.indexOf("modal.querySelector('#storePublish')?.addEventListener"));
  const cap = publish.indexOf('captureConfig();');
  const rev = publish.indexOf('SC.review(products, settings, sfLang)');
  const build = publish.indexOf('await buildCatalog(');
  assert.ok(cap > 0 && rev > cap && build > rev, 'capture → review → build');
  assert.match(publish, /if \(!\(await confirmModal\(/, 'the shop can stop the publish');
  assert.match(publish, /\{ captured: true \}/, 'the form is not read twice');
});

test('every issue key the shared review returns has a label here', () => {
  // Literal keys, so the locale reachability test can see them.
  for (const k of ['no_price', 'no_photo', 'no_description', 'no_category', 'second_language', 'file_name']) {
    assert.match(dialog, new RegExp(`${k}: t\\('store\\.issue_${k}'\\)`), k);
  }
});
