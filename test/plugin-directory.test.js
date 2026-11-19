const { test } = require('node:test');
const assert = require('node:assert/strict');
const M = require('../lib/plugin-manifest.js');
const D = require('../lib/plugin-directory.js');
const lamha = require('../plugins/samples/lamha-shipping.json');

const listing = (over = {}) => ({
  id: lamha.id, kind: 'connector', name: 'Lamha Shipping', summary: 'Create shipments from a job.',
  category: 'shipping', licence: 'MIT', support: 'mailto:support@khaytapp.com',
  publisher: { name: 'Khayt', namespace: lamha.id.split('.').slice(0, 2).join('.'), verifiedDomain: 'khaytapp.com' },
  ...over,
});
const row = (over = {}) => ({ kind: 'connector', id: lamha.id, version: lamha.version, url: 'https://khaytapp.com/x.json', sha256: 'a'.repeat(64), ...over });
const slicer = (over = {}) => ({
  kind: 'slicer', id: 'app.khayt.orca', version: '0.1.0', host: 'orca', hostVersion: '>=2.5.1',
  package: { name: 'khayt-orca', file: 'khayt_orca-0.1.0-py3-none-any.whl', sha256: 'b'.repeat(64), size: 120000 },
  requires: { khayt: { mac: '4.0.0' } }, scopes: ['slices:send', 'queue:read'],
  hostPermissions: ['threading', 'fs_readwrite:~/.khayt-orca'], source: 'https://github.com/KhaytApp/khayt-orca', licence: 'MIT', ...over,
});
const slicerListing = (over = {}) => listing({ id: 'app.khayt.orca', kind: 'slicer', name: 'Khayt for OrcaSlicer', category: 'slicer',
  source: 'https://github.com/KhaytApp/khayt-orca', publisher: { name: 'Khayt', namespace: 'app.khayt' }, ...over });

test('a listing describes and never grants: permissions, fields, domains, scopes and prices are refused', () => {
  assert.deepEqual(D.checkListing(listing()), []);
  for (const k of D.GRANTING_KEYS) {
    const e = D.checkListing(listing({ [k]: ['x'] }));
    assert.ok(e.some((x) => x.startsWith(k + ':') && x.includes('signed manifest')), k);
  }
  assert.ok(D.checkListing(listing({ colour: 'red' })).some((x) => x.startsWith('colour')), 'unknown keys refused');
});

test('code must publish source; a data-only connector may be closed (Turki, Nov 17)', () => {
  assert.deepEqual(D.checkListing(listing()), [], 'a connector needs no source');
  for (const kind of D.CODE_KINDS) {
    assert.ok(D.checkListing(listing({ kind })).some((x) => x.startsWith('source:')), kind + ' without source');
    assert.deepEqual(D.checkListing(listing({ kind, source: 'https://github.com/x/y' })), [], kind + ' with source');
  }
});

test('the id lives under the publisher namespace; licence is SPDX; Arabic is optional', () => {
  assert.ok(D.checkListing(listing({ id: 'com.other.thing' })).some((x) => x.includes('namespace')));
  assert.ok(D.checkListing(listing({ licence: 'my own' })).some((x) => x.startsWith('licence')));
  assert.deepEqual(D.checkListing(listing({ licence: 'Apache-2.0 OR MIT' })), []);
  const p = D.pageFor(listing(), row(), lamha);
  assert.equal(p.descriptionArFallback, true, 'no Arabic: the page falls back to the English');
  assert.equal(D.pageFor(listing({ descriptionAr: 'شحن' }), row(), lamha).descriptionArFallback, false);
});

test('a connector page shows exactly the consent sheet\'s rows, computed from the signed manifest', () => {
  const p = D.pageFor(listing(), row(), lamha);
  assert.equal(p.state, 'listed');
  assert.equal(p.version, lamha.version);
  assert.deepEqual(p.permissions.sends, M.consentRows(lamha));
  assert.deepEqual(p.permissions.scopes, (lamha.scopes || []).slice().sort());
  assert.equal(p.free, true);
  assert.deepEqual(p.worksIn, { install: ['mac', 'desktop'], runs: ['mac', 'desktop', 'ios'] });
  assert.equal(D.pageFor(listing(), row({ version: '9.9.9' }), lamha).error, 'mismatch', 'the manifest must be the row\'s version');
  assert.equal(D.pageFor(listing(), row({ id: 'com.x.y' }), lamha).error, 'mismatch');
});

test('states: not released, coming, deprecated, withdrawn with its reason', () => {
  assert.equal(D.pageFor(listing(), null, null).state, 'not-released');
  assert.equal(D.pageFor(listing({ kind: 'plugin', source: 'https://github.com/x/y' }), null, null).state, 'coming');
  assert.equal(D.pageFor(listing({ deprecated: true }), row(), lamha).state, 'deprecated');
  const w = D.pageFor(listing(), row({ revoked: [{ version: lamha.version, reason: 'Reports a refused order as sent.' }] }), lamha);
  assert.deepEqual([w.state, w.withdrawnReason], ['withdrawn', 'Reports a refused order as sent.']);
});

test('a slicer package: signed record, scopes as the Mac shows them, never printer control; not released until signed', () => {
  assert.deepEqual(D.checkSlicerRecord(slicer()), []);
  assert.ok(D.checkSlicerRecord(slicer({ scopes: ['slices:send', 'printer:send'] })).some((x) => x.startsWith('scopes')));
  assert.ok(D.checkSlicerRecord(slicer({ source: undefined })).some((x) => x.startsWith('source')));
  assert.ok(D.checkSlicerRecord(slicer({ package: { name: 'khayt-orca', file: 'x.whl', sha256: 'nope', size: 1 } })).some((x) => x.startsWith('package')));
  assert.ok(D.checkSlicerRecord(slicer({ host: 'cura' })).some((x) => x.startsWith('host')));
  const none = D.pageFor(slicerListing(), null, null);
  assert.deepEqual([none.state, none.download], ['not-released', null], 'nothing to download before a signed release');
  const rec = slicer();
  const p = D.pageFor(slicerListing(), { ...rec, url: 'https://khaytapp.com/connectors/app.khayt.orca/0.1.0.whl' }, rec);
  assert.equal(p.state, 'listed');
  assert.deepEqual(p.download, { file: rec.package.file, sha256: rec.package.sha256, size: rec.package.size, url: 'https://khaytapp.com/connectors/app.khayt.orca/0.1.0.whl' });
  assert.deepEqual(p.permissions, { pairing: ['slices:send', 'queue:read'], hostPermissions: rec.hostPermissions, printerControl: false });
  assert.deepEqual(p.worksIn, { host: 'OrcaSlicer', hostVersion: '>=2.5.1', pairedWith: 'mac' });
  const gone = D.pageFor(slicerListing(), { ...rec, revoked: [{ version: '0.1.0', reason: 'x' }] }, rec);
  assert.deepEqual([gone.state, gone.download], ['withdrawn', null], 'a withdrawn package offers no download');
});

test('the apps ignore the slicer kind today (it is not one of plugin-update KINDS), so the index can carry it safely', () => {
  const U = require('../lib/plugin-update.js');
  assert.ok(!U.KINDS.includes('slicer'));
});
