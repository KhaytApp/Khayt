const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  redactStatusHtmlClientRow,
  prepareStatusHtmlForServe,
  prepareInteractiveHtmlForFile,
} = require('../lib/status-html');

test('redactStatusHtmlClientRow removes client info row', () => {
  const html = '<div class="info-row"><span class="info-label">Client</span><span class="info-value">Secret</span></div><div class="info-row"><span class="info-label">Status</span></div>';
  const out = redactStatusHtmlClientRow(html);
  assert.doesNotMatch(out, /Secret/);
  assert.match(out, /Status/);
});

test('prepareStatusHtmlForServe strips script tags', () => {
  const html = '<script>alert(1)</script><p>ok</p>';
  const out = prepareStatusHtmlForServe(html);
  assert.doesNotMatch(out, /<script/i);
  assert.match(out, /ok/);
});

test('prepareInteractiveHtmlForFile keeps scripts but blocks javascript href', () => {
  const html = '<script>ok()</script><a href="javascript:alert(1)">x</a>';
  const out = prepareInteractiveHtmlForFile(html);
  assert.match(out, /<script>ok\(\)<\/script>/);
  assert.doesNotMatch(out, /javascript:/i);
});
