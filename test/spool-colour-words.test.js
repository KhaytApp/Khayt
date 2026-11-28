'use strict';
/**
 * Windows/Linux: a spool's colour is a swatch with an outline plus its NAME,
 * never its hex code (Turki, Nov 27; lib/colour-name.js, #2736). The words come
 * from renderer/app-helpers.js spoolColourWord; the swatch is colourSwatchHtml.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const H = require('../renderer/app-helpers.js');

const HEX = /#[0-9a-f]{6}\b/i;

test('the words: the spool\'s own name wins, else the nearest everyday name, else nothing; never a code', () => {
  assert.equal(H.spoolColourWord({ color: '#080A0D' }), 'Black');
  assert.equal(H.spoolColourWord({ color: '#FFFFFF', colourVariant: 'Galaxy Black' }), 'Galaxy Black', 'the maker\'s own name');
  assert.equal(H.spoolColourWord({ color: '#FFFFFF', colorName: 'Snow' }), 'Snow', 'a tag\'s colour name');
  assert.equal(H.spoolColourWord({ hex: '#D62828', known: '' }), 'Red', 'the {hex, known} shape');
  assert.doesNotMatch(H.spoolColourWord({ color: '#123456', colourVariant: '#123456' }), HEX, 'a "name" that is just a code is not used');
  assert.equal(H.spoolColourWord({}), '');
  assert.equal(H.spoolColourWord(null), '');
  assert.equal(H.spoolColourWord({ color: 'not a colour' }), '', 'no colour: no words, the swatch alone');
});

test('the swatch: outlined, and hidden from a screen reader (its name is read, never its code)', () => {
  const s = H.colourSwatchHtml('#FFFFFF', 12);
  assert.match(s, /aria-hidden="true"/);
  assert.match(s, /box-shadow:0 0 0 1px/, 'an outline, so white on white still shows');
  assert.match(s, /width:12px;height:12px/);
  assert.doesNotMatch(s.replace(/background:[^;]+;/, ''), HEX, 'the code is only the paint');
  assert.match(H.colourSwatchHtml('javascript:alert(1)'), /background:#888888/, 'an unsafe value is not painted');
});

test('every place the window shows a spool\'s colour asks for its words, not its code', () => {
  const read = (f) => fs.readFileSync(path.join(__dirname, '..', 'renderer', f), 'utf8');
  const inv = read('inventory.js');
  assert.match(inv, /const colourWord = spoolColourWord\(item\);/, 'inventory list');
  assert.match(inv, /\$\{colourSwatchHtml\(item\.color, 10\)\}\s*\n\s*<span style="flex:1;font-size:12\.5px;font-weight:600;">\$\{escapeHtml\(item\.material\)\}\$\{spoolColourWord\(item\)/, 'low-stock alert');
  assert.match(inv, /\$\{spoolColourWord\(item\) \? `<span>\$\{escapeHtml\(spoolColourWord\(item\)\)\}<\/span>` : ''\}/, 'printed label');
  assert.match(inv, /const tagColour = spoolColourWord\(\{ hex: nfcData\.hex, known: nfcData\.colorName \|\| '' \}\);/, 'NFC scan');
  assert.match(read('dashboard.js'), /dash-low-spool">\$\{colourSwatchHtml\(i\.color, 8\)\}/, 'dashboard low stock');
  const mach = read('machines.js');
  assert.match(mach, /spoolColourWord\(\{ hex: r\.hex, known: \(r\.spool && r\.spool\.colourVariant\) \|\| '' \}\)/, 'printer head rows');
  assert.match(mach, /const word = typeof spoolColourWord === 'function' \? spoolColourWord\(s\)/, 'a linked spool\'s label');
  assert.match(read('kanban.js'), /const word = spoolColourWord\(inv\);/, 'job card swatch');
  const conv = read('converter-spools.js');
  assert.doesNotMatch(conv, /\|\| hexOf\(i\.color\);/, 'the converter\'s spool label never falls back to the code');
  for (const f of ['color-planner.js', 'colorstudio.js']) assert.match(read(f), /spoolColourWord\(it\)/, f + ' spool labels');
  for (const page of ['index.html', 'bedready.html']) {
    const html = read(page);
    assert.ok(html.indexOf('../lib/colour-name.js') > html.indexOf('../lib/color-mix.js'), page + ': colour-name loads after color-mix');
  }
});
