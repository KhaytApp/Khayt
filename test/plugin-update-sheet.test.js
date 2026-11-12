'use strict';
/**
 * The connector update sheet's content (lib/plugin-update-sheet.js): what is
 * NEW first, each line tagged New or New place, then what the shop already
 * agreed to — read against the grant, every app in the same order.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const M = require('../lib/plugin-manifest.js');
require('../lib/plugin-host.js');
const U = require('../lib/plugin-update.js');
const S = require('../lib/plugin-update-sheet.js');

/** A sample connector with two hosts; `toA`/`toB` are what each is sent. */
function sample(version, toA, toB, { keyAt = 'a', scopes } = {}) {
  return {
    khayt: { manifest: 1 }, id: 'app.test.courier', name: { en: 'Sample Courier' }, publisher: 'Test', version,
    domains: ['api.example.com', 'tracking.example.com'],
    secrets: [{ name: 'key', label: { en: 'API key' }, kind: 'token' }],
    ...(scopes ? { scopes } : {}),
    actions: [
      { id: 'one', label: { en: 'Ship' }, placement: 'order', kind: 'post', url: 'https://api.example.com/x',
        ...(keyAt === 'a' ? { auth: { header: 'X-K', secret: 'key' } } : {}),
        body: { format: 'json-template', template: toA } },
      { id: 'two', label: { en: 'Track' }, placement: 'order', kind: 'post', url: 'https://tracking.example.com/y',
        ...(keyAt === 'b' ? { auth: { header: 'X-K', secret: 'key' } } : {}),
        body: { format: 'json-template', template: toB } },
    ],
  };
}
const V1 = sample('2.0.0', { n: '{customer.name}', p: '{customer.phone}', j: '{order.number}' }, { t: '{order.id}' });
// 2.1.0: the address is new, and the job number now also goes to tracking.
const V2 = sample('2.1.0', { n: '{customer.name}', p: '{customer.phone}', a: '{customer.address}', j: '{order.number}' },
  { t: '{order.id}', j: '{order.number}' });

function entryAt(m) {
  return { id: m.id, version: m.version, enabled: true, manifest: m, granted: M.grantFor(m), config: {} };
}
const pendingOf = (m, entry) => ({ version: m.version, manifest: m, diff: M.diffPermissions(entry.granted, m), offeredAt: '2026-11-12T09:00:00.000Z' });

test('the sample manifests validate (so the sheet is read off real shapes)', () => {
  for (const m of [V1, V2]) { const v = M.validateManifest(m); assert.ok(v.ok, v.errors.join('; ')); }
});

test('NEW first, by host, each line tagged; a field sent to a new host is "New place"', () => {
  const e = entryAt(V1);
  const sh = S.sheetFor(e, pendingOf(V2, e));
  assert.equal(sh.asksMore, true);
  assert.deepEqual([sh.from, sh.to], ['2.0.0', '2.1.0']);
  assert.deepEqual(sh.fresh, [
    { host: 'api.example.com', items: [{ kind: 'field', key: 'customer.address', tag: 'new' }] },
    { host: 'tracking.example.com', items: [{ kind: 'field', key: 'order.number', tag: 'new_place' }] },
  ]);
  // Already agreed: what is still sent and covered by the grant, quieter.
  assert.deepEqual(sh.agreed.map((r) => [r.host, r.items.map((i) => i.key)]), [
    ['api.example.com', ['customer.name', 'customer.phone', 'order.number', 'key']],
    ['tracking.example.com', ['order.id']],
  ]);
});

test('within a host, New comes before New place', () => {
  const e = entryAt(V1);
  const v3 = sample('2.2.0', { n: '{customer.name}' }, { t: '{order.id}', z: '{customer.phone}', a: '{customer.email}' });
  const sh = S.sheetFor(e, pendingOf(v3, e));
  const tracking = sh.fresh.find((r) => r.host === 'tracking.example.com');
  assert.deepEqual(tracking.items.map((i) => [i.key, i.tag]), [['customer.email', 'new'], ['customer.phone', 'new_place']]);
});

test('a key sent to the other host is a New place; new scopes are listed', () => {
  const e = entryAt(V1);
  const moved = sample('2.1.0', { n: '{customer.name}', p: '{customer.phone}', j: '{order.number}' }, { t: '{order.id}' },
    { keyAt: 'b', scopes: ['fields.write'] });
  const sh = S.sheetFor(e, pendingOf(moved, e));
  assert.deepEqual(sh.fresh, [{ host: 'tracking.example.com', items: [{ kind: 'secret', key: 'key', tag: 'new_place' }] }]);
  assert.deepEqual(sh.scopes, ['fields.write']);
});

test('asking for nothing more: no New section, everything under Already agreed', () => {
  const e = entryAt(V2);
  const same = Object.assign(JSON.parse(JSON.stringify(V2)), { version: '2.1.1' });
  const sh = S.sheetFor(e, pendingOf(same, e));
  assert.equal(sh.asksMore, false);
  assert.deepEqual(sh.fresh, []);
  assert.equal(sh.agreed.length, 2);
});

test('a grant from before routes were kept: a field it listed is agreed on every host it listed', () => {
  const g = M.grantFor(V1);
  const e = Object.assign(entryAt(V1), { granted: { version: g.version, fields: g.fields, domains: g.domains, scopes: g.scopes } });
  const sh = S.sheetFor(e, pendingOf(V2, e));
  assert.deepEqual(sh.fresh, [{ host: 'api.example.com', items: [{ kind: 'field', key: 'customer.address', tag: 'new' }] }]);
});

test('waitingFor: only a pending version newer than the one installed', () => {
  const e = entryAt(V1);
  const st = { pending: pendingOf(V2, e) };
  assert.equal(S.waitingFor(e, st, U.compareVersions).version, '2.1.0');
  assert.equal(S.waitingFor(entryAt(V2), st, U.compareVersions), null, 'installed since by hand');
  assert.equal(S.waitingFor(e, {}, U.compareVersions), null);
  assert.equal(S.sheetFor(e, null), null);
});

test('JavaScriptCore-safe: runs with no require, module, global or window', () => {
  const vm = require('vm');
  const fs = require('fs');
  const path = require('path');
  const ctx = vm.createContext({});
  for (const f of ['plugin-manifest.js', 'plugin-update-sheet.js']) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'lib', f), 'utf8'), ctx, { filename: f });
  }
  const e = entryAt(V1);
  const out = vm.runInContext('KhaytPluginUpdateSheet', ctx).sheetFor(e, pendingOf(V2, e));
  assert.deepEqual(JSON.parse(JSON.stringify(out)), S.sheetFor(e, pendingOf(V2, e)));
});
