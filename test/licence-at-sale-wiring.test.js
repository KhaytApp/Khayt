/**
 * The licence warning and the CC BY credit are drawn where a sale is edited:
 * the job editor and the product editor. The rule lives in lib/model-licence.js
 * and the block in renderer/app-helpers.js; this checks both editors call it,
 * because a correct helper with no caller warns nobody.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const read = (f) => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');

test('the job editor draws the licence block from the job\'s parts', () => {
  const src = read('renderer/order-flows.js');
  const body = src.slice(src.indexOf('function openOrderEditor('));
  assert.match(body.slice(0, 20000), /licenceAtSaleHtml\(\(order\.parts \|\| \[\]\)\.map\(\(p\) => p && p\.printFileId\)\)/);
});

test('the product editor draws it, redraws it with the parts, and can add the credit', () => {
  const src = read('renderer/inventory.js');
  const body = src.slice(src.indexOf('function openProductEditor('));
  assert.match(body, /<div id="prodLicence">\$\{licenceHtml\(\)\}<\/div>/);
  assert.match(body, /function refreshParts\(\) \{\s*partsContainer\.innerHTML = partsHtml\(\);\s*refreshLicence\(\);/);
  assert.match(body, /data-act="licence-credit-add"/);
});

test('the block: a warning for a non-commercial model, a credit for CC BY, nothing for unknown', () => {
  require('../lib/model-licence.js');
  global.t = (k, p) => k + (p ? JSON.stringify(p) : '');
  global.escapeHtml = (s) => String(s);
  global.localDateStr = () => '2026-10-30';
  global.printFiles = [
    { id: 'NC', name: 'Owl', licence: 'cc-by-nc' },
    { id: 'BY', name: 'Vase', licence: 'cc-by', source: 'Ana' },
    { id: 'UNK', name: 'Bracket' },
  ];
  const H = require('../renderer/app-helpers.js');
  const both = H.licenceAtSaleHtml(['NC', 'BY'], { creditButton: true });
  assert.match(both, /lic\.not_for_sale/);
  assert.match(both, /lic\.nc_line\{"name":"Owl"\}/);
  assert.match(both, /“Vase” — Ana \(CC BY\)/);
  assert.match(both, /licence-credit-add/);
  assert.equal(H.licenceAtSaleHtml(['UNK']), '', 'unknown is not no');
  // Once the description carries the line, the button goes.
  const written = '“Vase” — Ana (CC BY)';
  assert.doesNotMatch(H.licenceAtSaleHtml(['BY'], { creditButton: true, written }), /licence-credit-add/);
  assert.equal(H.licenceCreditText(['BY'], ''), 'lic.credit_lead “Vase” — Ana (CC BY)');
  assert.equal(H.licenceCreditText(['BY'], written), '');
});

test('the block: a remix of a non-commercial original says so', () => {
  require('../lib/model-licence.js');
  global.t = (k, p) => k + (p ? JSON.stringify(p) : '');
  global.escapeHtml = (s) => String(s);
  global.localDateStr = () => '2026-10-30';
  global.printFiles = [
    { id: 'NC', name: 'Owl', licence: 'cc-by-nc', sourceUrl: 'https://example.com/owl' },
    { id: 'RX', name: 'Owl, hollow', remixOf: 'https://example.com/owl/' },
  ];
  const H = require('../renderer/app-helpers.js');
  const html = H.licenceAtSaleHtml(['RX']);
  assert.match(html, /lic\.not_for_sale/);
  assert.match(html, /lic\.remix_line\{"name":"Owl, hollow","parent":"Owl"\}/);
});
