'use strict';

/**
 * A campaign email puts customer names into HTML: they are escaped there
 * (lib/campaigns.js fillTemplate opts.html, #1710), and only there.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const C = require('../lib/campaigns.js');

test('the email channel escapes merged values; WhatsApp and SMS stay plain', () => {
  const r = { client: { name: '<img src=x onerror=alert(1)> & Co' }, stats: { completedCount: 2 } };
  const html = C.fillTemplate('Hi {{name}}, {{orders}} orders', r, String, {}, { html: true });
  assert.doesNotMatch(html, /<img/);
  assert.match(html, /&lt;img/);
  assert.match(html, /&amp; Co/);
  assert.equal(C.fillTemplate('Hi {{name}}', r, String, {}), 'Hi <img src=x onerror=alert(1)> & Co', 'plain text is untouched');
});

test('the desktop sends email with the HTML fill', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'clients.js'), 'utf8');
  const at = src.indexOf("if (ch === 'email') {");
  assert.ok(at > 0);
  const block = src.slice(at, at + 700);
  assert.match(block, /fillTemplate\(body, r, fmtMoney, settings, \{ html: true \}\)/);
  assert.match(block, /body: html\.replace/);
});
