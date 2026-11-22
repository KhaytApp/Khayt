/**
 * Label sheet builder. Pure HTML — verifies card structure, line filtering,
 * QR embedding, and escaping (orders/spools come from user data).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { buildLabelSheet, esc } = require('../lib/labels.js');

test('builds one card per label with title, lines, and QR', () => {
  const html = buildLabelSheet([
    { title: 'A-101', lines: ['Acme Co', 'PLA', 'due 2026-06-28'], qr: 'data:image/svg+xml;base64,XXX' },
    { title: 'A-102', lines: ['Beta'], qr: 'data:image/svg+xml;base64,YYY' },
  ]);
  assert.equal((html.match(/lbl-card/g) || []).length, 2);
  assert.match(html, /A-101/);
  assert.match(html, /Acme Co/);
  assert.match(html, /src="data:image\/svg\+xml;base64,XXX"/);
});

test('blank/nullish lines are dropped', () => {
  const html = buildLabelSheet([{ title: 'X', lines: ['keep', '', null, '  '], qr: '' }]);
  assert.equal((html.match(/lbl-line/g) || []).length, 1);
});

test('escapes HTML in user fields', () => {
  const html = buildLabelSheet([{ title: '<b>x</b>', lines: ['a & "b"'], qr: '' }]);
  assert.match(html, /&lt;b&gt;x&lt;\/b&gt;/);
  assert.match(html, /a &amp; &quot;b&quot;/);
  assert.ok(!html.includes('<b>x</b>'));
});

test('optional heading + empty list', () => {
  assert.match(buildLabelSheet([], { heading: 'Spools' }), /lbl-heading">Spools/);
  assert.match(buildLabelSheet([]), /label-grid/);
});

test('esc handles null', () => {
  assert.equal(esc(null), '');
  assert.equal(esc('a<b'), 'a&lt;b');
});
