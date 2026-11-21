const { test } = require('node:test');
const assert = require('node:assert/strict');
const M = require('../lib/plugin-manifest.js');
const D = require('../lib/plugin-directory.js');
const lamha = require('../plugins/samples/lamha-shipping.json');

const listing = (over = {}) => ({
  id: lamha.id, kind: 'connector', name: 'Lamha Shipping', summary: 'Create shipments from a job.',
  category: 'shipping', licence: 'MIT', support: 'mailto:support@khaytapp.com',
  publisher: { name: 'Khayt', namespace: lamha.id.split('.').slice(0, 2).join('.') },
  ...over,
});
const row = (over = {}) => ({ kind: 'connector', id: lamha.id, version: lamha.version, url: 'https://khaytapp.com/x.json', sha256: 'a'.repeat(64), ...over });
const owner = { name: 'Khayt', namespace: lamha.id.split('.').slice(0, 2).join('.'), verifiedDomain: 'khaytapp.com' };
const orcaOwner = { name: 'Khayt', namespace: 'app.khayt', verifiedDomain: 'khaytapp.com' };
const slicer = (over = {}) => ({
  kind: 'slicer', id: 'app.khayt.orca', version: '0.1.0', host: 'orca', hostVersion: '>=2.5.1',
  package: { name: 'khayt-orca', file: 'khayt_orca-0.1.0-py3-none-any.whl', sha256: 'b'.repeat(64), size: 120000 },
  requires: { khayt: { mac: '4.0.0' } }, scopes: ['slices:send', 'queue:read'],
  hostPermissions: ['threading'], source: 'https://github.com/KhaytApp/khayt-orca', licence: 'MIT', ...over,
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
  const p = D.pageFor(listing(), row(), lamha, owner);
  assert.equal(p.descriptionArFallback, true, 'no Arabic: the page falls back to the English');
  assert.equal(D.pageFor(listing({ descriptionAr: 'شحن' }), row(), lamha, owner).descriptionArFallback, false);
});

test('a connector page shows exactly the consent sheet\'s rows, computed from the signed manifest', () => {
  const p = D.pageFor(listing(), row(), lamha, owner);
  assert.equal(p.state, 'listed');
  assert.equal(p.version, lamha.version);
  assert.deepEqual(p.permissions.sends, M.consentRows(lamha));
  assert.deepEqual(p.permissions.scopes, (lamha.scopes || []).slice().sort());
  assert.equal(p.free, true);
  assert.deepEqual(p.worksIn, { install: ['mac', 'desktop'], runs: ['mac', 'desktop', 'ios'] });
  assert.equal(D.pageFor(listing(), row({ version: '9.9.9' }), lamha, owner).error, 'mismatch', 'the manifest must be the row\'s version');
  assert.equal(D.pageFor(listing(), row({ id: 'com.x.y' }), lamha, owner).error, 'mismatch');
});

test('states: not released, coming, deprecated, withdrawn with its reason', () => {
  assert.equal(D.pageFor(listing(), null, null, owner).state, 'not-released');
  assert.equal(D.pageFor(listing({ kind: 'plugin', source: 'https://github.com/x/y' }), null, null, owner).state, 'coming');
  assert.equal(D.pageFor(listing({ deprecated: true }), row(), lamha, owner).state, 'deprecated');
  const w = D.pageFor(listing(), row({ revoked: [{ version: lamha.version, reason: 'Reports a refused order as sent.' }] }), lamha, owner);
  assert.deepEqual([w.state, w.withdrawnReason], ['withdrawn', 'Reports a refused order as sent.']);
});

test('a slicer package: signed record, scopes as the Mac shows them, never printer control; not released until signed', () => {
  assert.deepEqual(D.checkSlicerRecord(slicer()), []);
  assert.ok(D.checkSlicerRecord(slicer({ scopes: ['slices:send', 'printer:send'] })).some((x) => x.startsWith('scopes')));
  assert.ok(D.checkSlicerRecord(slicer({ source: undefined })).some((x) => x.startsWith('source')));
  assert.ok(D.checkSlicerRecord(slicer({ package: { name: 'khayt-orca', file: 'x.whl', sha256: 'nope', size: 1 } })).some((x) => x.startsWith('package')));
  assert.ok(D.checkSlicerRecord(slicer({ host: 'cura' })).some((x) => x.startsWith('host')));
  const none = D.pageFor(slicerListing(), null, null, orcaOwner);
  assert.deepEqual([none.state, none.download], ['not-released', null], 'nothing to download before a signed release');
  const rec = slicer();
  const p = D.pageFor(slicerListing(), { ...rec, url: 'https://khaytapp.com/connectors/app.khayt.orca/0.1.0.whl' }, rec, orcaOwner);
  assert.equal(p.state, 'listed');
  assert.deepEqual(p.download, { file: rec.package.file, sha256: rec.package.sha256, size: rec.package.size, url: 'https://khaytapp.com/connectors/app.khayt.orca/0.1.0.whl' });
  assert.deepEqual(p.permissions, { pairing: ['slices:send', 'queue:read'], hostPermissions: ['threading'], prices: 'none', printerControl: false });
  assert.deepEqual(p.worksIn, { host: 'OrcaSlicer', hostVersion: '>=2.5.1', pairedWith: 'mac' });
  const gone = D.pageFor(slicerListing(), { ...rec, revoked: [{ version: '0.1.0', reason: 'x' }] }, rec, orcaOwner);
  assert.deepEqual([gone.state, gone.download], ['withdrawn', null], 'a withdrawn package offers no download');
});

test('a slicer may ask for the tab price (price:read, cost:read on top), as the Mac names them (khayt-orca #7)', () => {
  // Vectors: [scopes, accepted, pairing shown, prices shown]
  const V = [
    [['slices:send', 'queue:read', 'price:read'], true, ['slices:send', 'queue:read', 'price:read'], 'price'],
    [['slices:send', 'queue:read', 'price:read', 'cost:read'], true, ['slices:send', 'queue:read', 'price:read', 'cost:read'], 'cost'],
    [['cost:read', 'price:read', 'queue:read', 'slices:send'], true, ['slices:send', 'queue:read', 'price:read', 'cost:read'], 'cost'],
    [['slices:send', 'cost:read'], false],
    [['slices:send', 'price:write'], false],
    [['slices:send', 'price:read', 'price:read'], false],
  ];
  for (const [scopes, ok, pairing, prices] of V) {
    const rec = slicer({ scopes });
    const errs = D.checkSlicerRecord(rec);
    assert.equal(errs.length === 0, ok, JSON.stringify(scopes) + ' ' + errs.join('; '));
    if (!ok) { assert.ok(errs.some((x) => x.startsWith('scopes')), JSON.stringify(scopes)); continue; }
    const p = D.pageFor(slicerListing(), { ...rec, url: 'https://khaytapp.com/connectors/app.khayt.orca/0.1.0.whl' }, rec, orcaOwner);
    assert.deepEqual([p.permissions.pairing, p.permissions.prices, p.permissions.printerControl], [pairing, prices, false], JSON.stringify(scopes));
  }
  // The Mac's own list, read from its source, is what this accepts: a new Mac scope fails here first.
  const fs = require('node:fs');
  const swift = fs.readFileSync(require('node:path').join(__dirname, '../mac/KhaytCore/Sources/KhaytApp/LanServer+Connector.swift'), 'utf8');
  const fn = swift.slice(swift.indexOf('func connectorScopes('), swift.indexOf('func connectorPriceGrant('));
  const macScopes = [...fn.matchAll(/"([a-z]+:[a-z]+)"/g)].map((m) => m[1]);
  assert.deepEqual(macScopes, D.SLICER_SCOPES);
});

test('the apps ignore the slicer kind today (it is not one of plugin-update KINDS), so the index can carry it safely', () => {
  const U = require('../lib/plugin-update.js');
  assert.ok(!U.KINDS.includes('slicer'));
});

test("review B1: who an item is from is the platform's record, never the listing's", () => {
  assert.ok(D.checkListing(listing({ publisher: { name: 'Khayt', namespace: owner.namespace, verifiedDomain: 'khaytapp.com' } }))
    .some((x) => x.startsWith('publisher.verifiedDomain')), 'a listing cannot claim a verified domain');
  assert.equal(D.pageFor(listing(), row(), lamha, null).error, 'owner', 'no owner record, no page');
  const impostor = { name: 'Not Khayt', namespace: 'com.attacker' };
  assert.equal(D.pageFor(listing(), row(), lamha, impostor).error, 'owner', 'an id under someone else\'s namespace is refused');
  const p = D.pageFor(listing({ publisher: { name: 'Totally Khayt', namespace: owner.namespace } }), row(), lamha, owner);
  assert.deepEqual(p.publisher, { name: 'Khayt', namespace: owner.namespace, verifiedDomain: 'khaytapp.com' }, 'the page shows the registry\'s name and domain, not the listing\'s');
});

test('review B2–B4: downloads from khaytapp.com only; host permissions plain; the record kind matches its row', () => {
  for (const url of ['http://khaytapp.com/x', 'https://evil.example/x', 'https://khaytapp.com.evil.example/x', 'https://user@khaytapp.com/x', 'https://khaytapp.com:8443/x']) {
    assert.equal(D.pageFor(listing(), row({ url }), lamha, owner).error, 'row-url', url);
  }
  assert.ok(D.onKhaytapp('https://khaytapp.com/connectors/x.json'));
  assert.ok(D.checkSlicerRecord(slicer({ hostPermissions: ['fs_readwrite:<script>'] })).some((x) => x.startsWith('hostPermissions')));
  assert.ok(D.checkSlicerRecord(slicer({ hostPermissions: ['fs_readwrite:"x"'] })).some((x) => x.startsWith('hostPermissions')));
  const rec = slicer();
  assert.equal(D.pageFor(slicerListing(), { ...rec, url: 'https://khaytapp.com/a.whl' }, { ...rec, kind: 'connector' }, orcaOwner).error, 'slicer-record');
});

test('review re-check: a connector page refuses a "manifest" that says it is another kind', () => {
  assert.equal(D.pageFor(listing(), row(), { ...lamha, kind: 'slicer' }, owner).error, 'mismatch');
  assert.equal(D.pageFor(listing(), row(), lamha, owner).state, 'listed');
});
