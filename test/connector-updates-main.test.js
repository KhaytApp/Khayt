'use strict';
/**
 * The desktop's half of connector updates (lib/main/connector-updates.js):
 * the index and every manifest are verified here before lib/plugin-update.js
 * sees them, and the shop's answers are applied to the store on disk.
 * Throwaway signing keys only.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const M = require('../lib/plugin-manifest.js');
require('../lib/plugin-host.js');
const U = require('../lib/plugin-update.js');
const C = require('../lib/main/connector-updates.js');

function throwawayKey(id) {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  const raw = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');
  return { id, key: raw, sign: (msg) => crypto.sign(null, Buffer.from(msg, 'utf8'), privateKey).toString('base64') };
}
const K1 = throwawayKey('test-key-1');
const K2 = throwawayKey('test-key-2');
const KEYS = [{ id: K1.id, key: K1.key }];

const NOW = Date.parse('2026-11-12T09:00:00.000Z');
const DAY = 24 * 3600 * 1000;
const LAMHA = require('../plugins/samples/lamha-shipping.json');
const at = (v) => { const m = Object.assign(JSON.parse(JSON.stringify(LAMHA)), { version: v }); delete m.signature; return m; };
const narrow = (v) => JSON.parse(JSON.stringify(at(v)).split('"{customer.email}"').join('""'));
const signManifest = (m, k = K1) => Object.assign({}, m, { signature: k.sign(M.canonicalJSON(m)) });
const bytesOf = (m) => Buffer.from(JSON.stringify(m), 'utf8');
const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');

function signIndex(ix, k = K1) {
  const unsigned = Object.assign({}, ix); delete unsigned.signature;
  return Object.assign({}, unsigned, { signature: { keyId: k.id, sig: k.sign(U.indexSigningMessage(unsigned)) } });
}
function indexFor(version, sha256, extra) {
  return Object.assign({ khaytIndex: 1, serial: 3, issuedAt: new Date(NOW - DAY).toISOString(), expires: new Date(NOW + 40 * DAY).toISOString(),
    entries: [{ kind: 'connector', id: LAMHA.id, version, url: `https://khaytapp.com/connectors/${LAMHA.id}/${version}.json`, sha256 }] }, extra || {});
}
function installedNarrow() {
  const m = signManifest(narrow('1.0.0'));
  return { id: m.id, version: '1.0.0', enabled: true, manifest: m, granted: M.grantFor(m), config: {}, secrets: { apiToken: 'sample-token' } };
}
const CTX = { platform: 'desktop', appVersion: '4.9.0', schema: 1, nowMs: NOW };
function fetcher(files) {
  return async (url) => { if (!(url in files)) throw new Error('404'); return files[url]; };
}

test('the index signature is checked over the context-prefixed bytes, with the key it names', () => {
  const ix = signIndex(indexFor('1.1.1', 'a'.repeat(64)));
  assert.equal(C.indexSignedBy(ix, KEYS), K1.id);
  assert.equal(C.indexSignedBy(Object.assign({}, ix, { serial: 4 }), KEYS), null, 'a changed index no longer verifies');
  assert.equal(C.indexSignedBy(signIndex(indexFor('1.1.1', 'a'.repeat(64)), K2), KEYS), null, 'an unknown key');
  const lying = Object.assign({}, ix, { signature: Object.assign({}, ix.signature, { keyId: 'other' }) });
  assert.equal(C.indexSignedBy(lying, [...KEYS, { id: 'other', key: K2.key }]), null, 'the key it names must be the one that signed');
  // A manifest-style signature over the bare JSON does not pass for an index's.
  const bare = Object.assign({}, ix, { signature: { keyId: K1.id, sig: K1.sign(M.canonicalJSON(indexFor('1.1.1', 'a'.repeat(64)))) } });
  assert.equal(C.indexSignedBy(bare, KEYS), null);
});

test('a manifest is handed over only when its bytes match the sha256 AND it is signed by Khayt', () => {
  const good = signManifest(at('1.1.1'));
  const b = bytesOf(good);
  assert.equal(C.verifiedManifest(b, sha(b), KEYS).version, '1.1.1');
  assert.equal(C.verifiedManifest(b, 'b'.repeat(64), KEYS), null, 'other bytes than promised');
  const unsigned = bytesOf(at('1.1.1'));
  assert.equal(C.verifiedManifest(unsigned, sha(unsigned), KEYS), null, 'unsigned');
  const other = bytesOf(signManifest(at('1.1.1'), K2));
  assert.equal(C.verifiedManifest(other, sha(other), KEYS), null, 'signed by a key that is not Khayt\'s');
});

test('a whole check: a verified update that asks for more waits, the installed version unchanged', async () => {
  const settings = { plugins: [installedNarrow()] };
  const m = signManifest(at('1.1.1')); const b = bytesOf(m);
  const ix = signIndex(indexFor('1.1.1', sha(b)));
  const r = await C.check(settings, { ctx: CTX, keys: KEYS, fetchBytes: fetcher({ [C.INDEX_URL]: bytesOf(ix), [ix.entries[0].url]: b }) });
  assert.equal(r.ok, true);
  assert.equal(r.settings.plugins[0].version, '1.0.0');
  assert.equal(U.stateOf(r.settings, LAMHA.id).pending.version, '1.1.1');
  assert.equal(r.settings.connectorUpdates.serial, 3);
});

test('a check fails safe: unsigned index, tampered manifest, or no network change nothing', async () => {
  const settings = { plugins: [installedNarrow()] };
  const m = signManifest(at('1.1.1')); const b = bytesOf(m);
  const ix = indexFor('1.1.1', sha(b));
  const unsigned = await C.check(settings, { ctx: CTX, keys: KEYS, fetchBytes: fetcher({ [C.INDEX_URL]: bytesOf(ix), [ix.entries[0].url]: b }) });
  assert.equal(unsigned.settings, settings);
  assert.equal(unsigned.reason, 'unsigned');
  const signed = signIndex(ix);
  const tampered = Buffer.from(b.toString('utf8').replace('Lamha', 'Lamhaa'), 'utf8');
  const t = await C.check(settings, { ctx: CTX, keys: KEYS, fetchBytes: fetcher({ [C.INDEX_URL]: bytesOf(signed), [ix.entries[0].url]: tampered }) });
  // A tampered manifest is not handed over, so the connector is untouched;
  // the index itself verified, so its serial is remembered (#2426) and the
  // check reports a change, for main to save.
  assert.equal(t.settings.plugins, settings.plugins);
  assert.equal(t.settings.connectorUpdates.serial, 3);
  assert.equal(t.changed, true);
  assert.equal(U.stateOf(t.settings, LAMHA.id).pending, undefined);
  const off = await C.check(settings, { ctx: CTX, keys: KEYS, fetchBytes: fetcher({}) });
  assert.equal(off.settings, settings);
});

test('Agree, applied to the store: the new version, granted what was shown, the keys kept on the same host', () => {
  const settings = { plugins: [installedNarrow()] };
  const pending = U.applyIndex(settings, signIndex(indexFor('1.1.1', 'a'.repeat(64))), Object.assign({ signedBy: K1.id }, CTX),
    { [LAMHA.id]: signManifest(at('1.1.1')) }).settings;
  const store = { printLog: [{ id: 'o1' }], settings: pending };
  const r = C.applyOp(store, { op: 'agree', id: LAMHA.id, nowMs: NOW });
  assert.equal(r.ok, true);
  const e = r.store.settings.plugins[0];
  assert.equal(e.version, '1.1.1');
  assert.deepEqual(e.secrets, { apiToken: 'sample-token' });
  assert.deepEqual(r.store.printLog, [{ id: 'o1' }], 'the rest of the store is untouched');
  assert.equal(U.stateOf(r.store.settings, LAMHA.id).pending, undefined);
  assert.equal(C.applyOp(r.store, { op: 'agree', id: LAMHA.id }).ok, false, 'nothing left to agree to');
});

// Keys and hosts, the rule the Mac keeps too: per key, the set of hosts the
// grant's routes send it to, before and after.
const KEYED = (routes, domains) => ({ id: 'app.test.keys', secrets: { a: 'sample-a', b: 'sample-b' },
  manifest: { domains: domains || ['one.example.com', 'two.example.com'] },
  granted: Object.assign({ domains: domains || ['one.example.com', 'two.example.com'] }, routes ? { routes } : {}) });

test('keys: one key sent to a new host is dropped, the other kept', () => {
  const before = KEYED(['one.example.com secret:a', 'one.example.com secret:b', 'one.example.com order.id']);
  const after = KEYED(['one.example.com secret:a', 'two.example.com secret:b', 'one.example.com order.id']);
  assert.deepEqual(C.keysWhereEntered(before, after).secrets, { a: 'sample-a' });
});

test('keys: a grant with no routes whose hosts changed drops every key', () => {
  const before = KEYED(null, ['one.example.com']);
  const after = KEYED(['one.example.com secret:a', 'one.example.com secret:b'], ['one.example.com', 'two.example.com']);
  assert.equal(C.keysWhereEntered(before, after).secrets, undefined);
  // Same hosts, no routes: the older grant is read as what its OWN manifest
  // sends (lib grantWithPairs). This fixture's manifest sends no key at all,
  // so key a now going to one.example.com is a move and only a is dropped.
  // (Before #2426 the desktop kept both here: hosts alone said nothing moved.)
  assert.deepEqual(C.keysWhereEntered(KEYED(null), KEYED(['one.example.com secret:a'])).secrets, { b: 'sample-b' });
  // With a real manifest (Lamha) that sends its key to the same host, an
  // older grant gaining its pairs keeps the key.
  const g = M.grantFor(LAMHA); const old = Object.assign({}, g); delete old.routes;
  const e = (granted) => ({ id: LAMHA.id, manifest: LAMHA, granted, secrets: { apiToken: 'sample-token' } });
  assert.deepEqual(C.keysWhereEntered(e(old), e(g)).secrets, { apiToken: 'sample-token' });
});

test('keys: nothing moved, every key kept', () => {
  const g = ['one.example.com secret:a', 'two.example.com secret:b'];
  assert.deepEqual(C.keysWhereEntered(KEYED(g), KEYED(g.slice().concat(['one.example.com order.id']))).secrets, { a: 'sample-a', b: 'sample-b' });
});

test('keys: the desktop drops exactly what the shared keysToForget names (cross-check)', () => {
  const cases = [
    [KEYED(['one.example.com secret:a', 'one.example.com secret:b', 'one.example.com order.id']),
     KEYED(['one.example.com secret:a', 'two.example.com secret:b', 'one.example.com order.id']), ['b']],
    [KEYED(null, ['one.example.com']),
     KEYED(['one.example.com secret:a', 'one.example.com secret:b'], ['one.example.com', 'two.example.com']), ['a', 'b']],
    [KEYED(['one.example.com secret:a', 'two.example.com secret:b']),
     KEYED(['one.example.com secret:a', 'two.example.com secret:b', 'one.example.com order.id']), []],
  ];
  for (const [before, after, dropped] of cases) {
    assert.deepEqual(U.keysToForget(before, after), dropped);
    const kept = C.keysWhereEntered(before, after).secrets || {};
    assert.deepEqual(Object.keys(after.secrets).filter((n) => !(n in kept)), dropped);
  }
});

test('forWindow masks every key', () => {
  const out = C.forWindow({ plugins: [installedNarrow()], connectorUpdates: { serial: 1, connectors: {} } }, 'MASK');
  assert.deepEqual(out.plugins[0].secrets, { apiToken: 'MASK' });
  assert.deepEqual(out.connectorUpdates, { serial: 1, connectors: {} });
});
