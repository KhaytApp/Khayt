'use strict';
/**
 * What a paired phone may change under `record.plugins` (lib/plugin-host.js
 * phoneRecord): the declared fields of a connector that is on, and nothing
 * else. The Mac's LAN route runs every phone record through it.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const M = require('../lib/plugin-manifest.js');
const H = require('../lib/plugin-host.js');

const { privateKey } = crypto.generateKeyPairSync('ed25519');
const sign = (m) => Object.assign({}, m, {
  signature: crypto.sign(null, Buffer.from(M.canonicalJSON(m), 'utf8'), privateKey).toString('base64'),
});
const manifest = (id, fields) => sign({
  khayt: { manifest: 1 }, id, name: { en: id }, publisher: 'Test', version: '1.0.0',
  domains: ['api.example.sa'], scopes: ['fields.write'], fields,
  actions: [{ id: 'go', label: { en: 'Go' }, placement: 'order', kind: 'open', url: 'https://api.example.sa/x' }],
});
const ship = H.consentedEntry(null, manifest('sa.test.ship', [
  { key: 'awb', label: { en: 'Air waybill' }, type: 'text', attach: 'order' },
  { key: 'boxes', label: { en: 'Boxes' }, type: 'number', attach: 'order' },
  { key: 'city', label: { en: 'City' }, type: 'text', attach: 'customer' },
]));
const off = Object.assign(H.consentedEntry(null, manifest('sa.test.off', [
  { key: 'ref', label: { en: 'Ref' }, type: 'text', attach: 'order' },
])), { enabled: false });
const settings = { plugins: [ship, off] };
const reviewed = ['sa.test.ship', 'sa.test.off'];
const held = { id: 'J-1', rev: 3, plugins: {
  'sa.test.ship': { awb: 'OLD', boxes: 2 }, 'sa.test.off': { ref: 'R-1' }, 'gone.connector': { x: 1 } } };

test('a phone fills a declared field of a connector that is on', () => {
  const rec = H.phoneRecord({ id: 'J-1', rev: 4, plugins: { 'sa.test.ship': { awb: 'AWB-9', boxes: '3' } } },
    held, settings, 'order', reviewed);
  assert.deepEqual(rec.plugins['sa.test.ship'], { awb: 'AWB-9', boxes: 3 });
  assert.equal(rec.rev, 4);
});

test('a phone cannot invent, wipe or reach past what is on', () => {
  const rec = H.phoneRecord({ id: 'J-1', rev: 4, plugins: {
    'sa.test.ship': { awb: 'AWB-9', boxes: 2, secret: 'x', city: 'Riyadh' },
    'sa.test.off': { ref: 'FORGED' },
    'made.up': { anything: 1 },
  } }, held, settings, 'order', reviewed);
  assert.deepEqual(rec.plugins['sa.test.ship'], { awb: 'AWB-9', boxes: 2 }, 'an undeclared or customer key landed on a job');
  assert.deepEqual(rec.plugins['sa.test.off'], { ref: 'R-1' }, 'a switched-off connector changed');
  assert.deepEqual(rec.plugins['gone.connector'], { x: 1 }, 'a removed connector\'s values were wiped');
  assert.equal(rec.plugins['made.up'], undefined, 'a phone invented a connector');
});

test('an unreviewed connector is not editable from a phone', () => {
  const rec = H.phoneRecord({ id: 'J-1', rev: 4, plugins: { 'sa.test.ship': { awb: 'AWB-9' } } },
    held, settings, 'order', []);
  assert.deepEqual(rec.plugins['sa.test.ship'], { awb: 'OLD', boxes: 2 });
});

test('a phone clears a value; a record without plugins keeps the Mac\'s', () => {
  const cleared = H.phoneRecord({ id: 'J-1', rev: 4, plugins: {} }, held, settings, 'order', reviewed);
  assert.equal(cleared.plugins['sa.test.ship'], undefined);
  assert.deepEqual(cleared.plugins['sa.test.off'], { ref: 'R-1' });
  const old = H.phoneRecord({ id: 'J-1', rev: 4, name: 'x' }, held, settings, 'order', reviewed);
  assert.deepEqual(old.plugins, held.plugins, 'an older phone build wiped connector values');
  const fresh = H.phoneRecord({ id: 'J-2', rev: 1 }, undefined, settings, 'order', reviewed);
  assert.equal('plugins' in fresh, false);
});

test('a customer takes only customer fields', () => {
  const rec = H.phoneRecord({ id: 'C-1', rev: 2, plugins: { 'sa.test.ship': { city: 'Jeddah', awb: 'X' } } },
    undefined, settings, 'customer', reviewed);
  assert.deepEqual(rec.plugins, { 'sa.test.ship': { city: 'Jeddah' } });
});

test('the entries above are valid, so the cases test the rule and not a broken fixture', () => {
  assert.equal(H.stateOf(ship, true), 'on');
  assert.equal(H.stateOf(off, true), 'off');
});

test('a connector\'s settings take only declared keys, each checked by type', () => {
  const m = Object.assign({}, ship.manifest, { settings: [
    { key: 'name', label: { en: 'Name' }, type: 'text', required: true },
    { key: 'count', label: { en: 'Count' }, type: 'number' },
    { key: 'live', label: { en: 'Live' }, type: 'bool' },
  ] });
  const e = Object.assign({}, ship, { manifest: m, config: { name: 'Old', count: 2 } });
  const next = H.withConfig(e, { name: '  Studio ', count: 'x', live: false, nope: 'y' });
  assert.deepEqual(next.config, { name: '  Studio ' }, 'a bad number or an unticked optional box was kept');
  assert.deepEqual(e.config, { name: 'Old', count: 2 }, 'the old entry was changed in place');
  assert.equal(H.withConfig(e, { name: 'x'.repeat(900) }).config.name.length, 500);
  assert.deepEqual(H.withConfig(e, { name: '' }).config, { count: 2 });
});
