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

// Keys and hosts: the shared rule, lib/plugin-update.js keysToForget (the Mac
// keeps the same). Per key, the hosts the grant's routes send it to, before and
// after; a grant from before pairs were kept is read as what its own manifest
// sends. Every fixture here is a valid manifest with a grant checkEntry passes
// (#2426 refuses a grant listing a route its manifest does not send).
const ONE = 'one.example.com';
const TWO = 'two.example.com';
/** A connector sending key `name` to host `to[name]`, and order.number to each `extra` host. */
function keyedManifest(version, to, extra) {
  const actions = Object.entries(to).map(([name, host]) => ({ id: 'send_' + name, label: { en: name }, placement: 'order', kind: 'post',
    url: `https://${host}/${name}`, auth: { header: 'X-Key', secret: name }, body: { format: 'json-template', template: { i: '{order.id}' } } }));
  for (const host of extra || []) actions.push({ id: 'ping_' + host.split('.')[0], label: { en: 'Ping' }, placement: 'order', kind: 'post',
    url: `https://${host}/ping`, body: { format: 'json-template', template: { n: '{order.number}' } } });
  return { khayt: { manifest: 1 }, id: 'app.test.keys', name: { en: 'Keys' }, publisher: 'Test', version,
    domains: Array.from(new Set(Object.values(to).concat(extra || []))).sort(),
    secrets: Object.keys(to).map((n) => ({ name: n, label: { en: n }, kind: 'token' })), actions };
}
function KEYED(version, to, extra, { legacy } = {}) {
  const manifest = keyedManifest(version, to, extra);
  const granted = M.grantFor(manifest);
  if (legacy) delete granted.routes;
  const e = { id: manifest.id, version, enabled: true, manifest, granted, config: {}, secrets: { a: 'sample-a', b: 'sample-b' } };
  assert.equal(M.checkEntry(e).ok, true, `fixture ${version} is a valid entry`);
  return e;
}
const KEY_CASES = {
  // 1. One key moves: only it drops.
  oneMoves: [KEYED('1.0.0', { a: ONE, b: ONE }), KEYED('1.1.0', { a: ONE, b: TWO }), ['b']],
  // 2. A grant with no routes, the hosts changed. Before #2426 the desktop
  //    dropped EVERY key here (hosts alone said nothing of which key went
  //    where). The shared rule reads the old grant as what its installed
  //    manifest sends, so only a key whose hosts really moved drops.
  legacyHostsChangedKeysStay: [KEYED('1.0.0', { a: ONE, b: ONE }, [], { legacy: true }), KEYED('1.1.0', { a: ONE, b: ONE }, [TWO]), []],
  legacyHostsChangedOneMoves: [KEYED('1.0.0', { a: ONE, b: ONE }, [], { legacy: true }), KEYED('1.1.0', { a: ONE, b: TWO }), ['b']],
  legacySameHosts: [KEYED('1.0.0', { a: ONE, b: TWO }, [], { legacy: true }), KEYED('1.1.0', { a: ONE, b: TWO }), []],
  // 3. Nothing moved (a new field only): every key kept.
  nothingMoved: [KEYED('1.0.0', { a: ONE, b: TWO }), KEYED('1.1.0', { a: ONE, b: TWO }, [ONE]), []],
};
const droppedBy = (before, after) => Object.keys(after.secrets).filter((n) => !(n in (C.keysWhereEntered(before, after).secrets || {})));

test('keys: one key sent to a new host is dropped, the other kept', () => {
  const [before, after] = KEY_CASES.oneMoves;
  assert.deepEqual(C.keysWhereEntered(before, after).secrets, { a: 'sample-a' });
});

test('keys: a grant with no routes whose hosts changed drops only the keys that moved', () => {
  assert.deepEqual(C.keysWhereEntered(...KEY_CASES.legacyHostsChangedKeysStay.slice(0, 2)).secrets, { a: 'sample-a', b: 'sample-b' });
  assert.deepEqual(C.keysWhereEntered(...KEY_CASES.legacyHostsChangedOneMoves.slice(0, 2)).secrets, { a: 'sample-a' });
  assert.deepEqual(C.keysWhereEntered(...KEY_CASES.legacySameHosts.slice(0, 2)).secrets, { a: 'sample-a', b: 'sample-b' });
  // Every key dropped leaves no `secrets` at all.
  const [before] = KEY_CASES.oneMoves;
  const both = KEYED('1.2.0', { a: TWO, b: TWO });
  assert.equal(C.keysWhereEntered(before, both).secrets, undefined);
});

test('keys: nothing moved, every key kept', () => {
  assert.deepEqual(C.keysWhereEntered(...KEY_CASES.nothingMoved.slice(0, 2)).secrets, { a: 'sample-a', b: 'sample-b' });
});

test('keys: the desktop drops exactly what the shared keysToForget names (cross-check)', () => {
  for (const [name, [before, after, dropped]] of Object.entries(KEY_CASES)) {
    assert.deepEqual(U.keysToForget(before, after), dropped, `lib, ${name}`);
    assert.deepEqual(droppedBy(before, after), dropped, `desktop, ${name}`);
  }
});

test('keys: a Revert through applyOp drops a key whose hosts move back', () => {
  const [v1, v2] = KEY_CASES.oneMoves;
  const settings = { plugins: [v2], connectorUpdates: { serial: 1, connectors: { [v2.id]: {
    previous: { version: v1.version, manifest: v1.manifest, granted: v1.granted }, updatedAt: '2026-11-12T09:00:00.000Z', updatedFrom: v1.version } } } };
  const r = C.applyOp({ settings }, { op: 'revert', id: v2.id });
  assert.equal(r.ok, true);
  const e = r.store.settings.plugins[0];
  assert.equal(e.version, '1.0.0');
  assert.deepEqual(e.granted, v1.granted, 'the grant is the kept one, from the lib');
  assert.deepEqual(e.secrets, { a: 'sample-a' });
});

// ── #2426's behaviour the desktop must carry ──
const IXCTX = Object.assign({ signedBy: K1.id }, CTX);
function installedFull(v = '1.0.0') {
  const m = signManifest(at(v));
  return { id: m.id, version: v, enabled: true, manifest: m, granted: M.grantFor(m), config: {}, secrets: { apiToken: 'sample-token' } };
}

test('a check that only raises the serial reports a change, so main saves it; the same serial again does not', () => {
  const settings = { plugins: [installedFull('1.1.1')], connectorUpdates: { serial: 3, connectors: {} } };
  const ix = signIndex(indexFor('1.1.1', 'a'.repeat(64), { serial: 4 }));
  const r = C.applyPrepared(settings, { index: ix, ctx: IXCTX, fetched: {} });
  assert.equal(r.ok, true);
  assert.equal(r.changed, true, 'main saves when changed is true (main.js hub:connector-updates-check)');
  assert.equal(r.settings.connectorUpdates.serial, 4);
  assert.equal(r.settings.plugins, settings.plugins, 'nothing else moved');
  const again = C.applyPrepared(r.settings, { index: ix, ctx: IXCTX, fetched: {} });
  assert.equal(again.changed, false);
  assert.equal(again.settings, r.settings);
});

test('a check whose index withdraws the waiting version drops it: no badge after the check', () => {
  const settings = { plugins: [installedNarrow()] };
  const waiting = U.applyIndex(settings, signIndex(indexFor('1.1.1', 'a'.repeat(64))), IXCTX, { [LAMHA.id]: signManifest(at('1.1.1')) }).settings;
  const S = require('../lib/plugin-update-sheet.js');
  assert.ok(S.waitingFor(waiting.plugins[0], U.stateOf(waiting, LAMHA.id), U.compareVersions), 'waiting first');
  const ix = signIndex(indexFor('1.1.1', 'a'.repeat(64), { serial: 4 }));
  ix.entries[0].revoked = [{ version: '1.1.1', reason: 'Sample withdrawal' }];
  const r = C.applyPrepared(waiting, { index: signIndex(ix), ctx: IXCTX, fetched: {} });
  assert.equal(r.changed, true);
  assert.equal(U.stateOf(r.settings, LAMHA.id).pending, undefined);
  assert.equal(S.waitingFor(r.settings.plugins[0], U.stateOf(r.settings, LAMHA.id), U.compareVersions), null);
  const w = C.forWindow(r.settings, 'MASK');
  assert.equal(U.stateOf({ connectorUpdates: w.connectorUpdates }, LAMHA.id).pending, undefined, 'the window is handed the state without it');
});

test('a withdrawn previous version: dropped by a check, and a Revert to one is refused with its reason', () => {
  // Automatic update 1.0.0 → 1.0.1 (sends less), so 1.0.0 is kept for Revert.
  const settings = { plugins: [installedFull('1.0.0')] };
  const auto = U.applyIndex(settings, signIndex(indexFor('1.0.1', 'a'.repeat(64))), IXCTX, { [LAMHA.id]: signManifest(narrow('1.0.1')) }).settings;
  assert.equal(auto.plugins[0].version, '1.0.1');
  assert.equal(U.stateOf(auto, LAMHA.id).previous.version, '1.0.0');
  // The index withdraws 1.0.0: the kept copy goes, so there is nothing to revert to.
  const ix = indexFor('1.0.1', 'a'.repeat(64), { serial: 4 });
  ix.entries[0].revoked = [{ version: '1.0.0', reason: 'Sample withdrawal' }];
  const r = C.applyPrepared(auto, { index: signIndex(ix), ctx: IXCTX, fetched: {} });
  const st = U.stateOf(r.settings, LAMHA.id);
  assert.equal(st.previous, undefined);
  assert.equal(st.previousWithdrawn, '1.0.0', 'the window says why there is no Revert from this field');
  assert.equal(C.forWindow(r.settings, 'MASK').connectorUpdates.connectors[LAMHA.id].previousWithdrawn, '1.0.0', 'and is handed it');
  assert.equal(C.applyOp({ settings: r.settings }, { op: 'revert', id: LAMHA.id }).ok, false);
  // A kept previous recorded as withdrawn (state from elsewhere): refused with 'revoked'.
  const forced = JSON.parse(JSON.stringify(auto));
  forced.connectorUpdates.connectors[LAMHA.id].revoked = { version: '1.0.0', reason: 'x', wasEnabled: true };
  const refused = C.applyOp({ settings: forced }, { op: 'revert', id: LAMHA.id });
  assert.deepEqual([refused.ok, refused.reason], [false, 'revoked']);
});

test('an automatic update that sends less narrows the stored grant; Revert puts the old one back', () => {
  const settings = { plugins: [installedFull('1.0.0')] };
  const before = settings.plugins[0].granted;
  assert.ok(before.fields.includes('customer.email'));
  const auto = U.applyIndex(settings, signIndex(indexFor('1.0.1', 'a'.repeat(64))), IXCTX, { [LAMHA.id]: signManifest(narrow('1.0.1')) }).settings;
  const e = auto.plugins[0];
  assert.equal(e.version, '1.0.1');
  assert.ok(!e.granted.fields.includes('customer.email'), 'narrowed to what 1.0.1 sends');
  assert.equal(M.checkEntry(e).ok, true, 'and still a valid entry');
  assert.deepEqual(C.forWindow(auto, 'MASK').plugins[0].granted, e.granted, 'the window is shown the entry\'s grant');
  const back = C.applyOp({ settings: auto }, { op: 'revert', id: LAMHA.id });
  assert.equal(back.ok, true);
  assert.deepEqual(back.store.settings.plugins[0].granted, before);
  assert.deepEqual(back.store.settings.plugins[0].secrets, { apiToken: 'sample-token' }, 'the key\'s host did not move');
});

test('an automatic update gives a grant without routes its pairs', () => {
  const old = installedFull('1.0.0'); delete old.granted.routes;
  const auto = U.applyIndex({ plugins: [old] }, signIndex(indexFor('1.0.1', 'a'.repeat(64))), IXCTX, { [LAMHA.id]: signManifest(at('1.0.1')) }).settings;
  assert.equal(auto.plugins[0].version, '1.0.1');
  assert.ok(Array.isArray(auto.plugins[0].granted.routes) && auto.plugins[0].granted.routes.length);
});

test('forWindow masks every key', () => {
  const out = C.forWindow({ plugins: [installedNarrow()], connectorUpdates: { serial: 1, connectors: {} } }, 'MASK');
  assert.deepEqual(out.plugins[0].secrets, { apiToken: 'MASK' });
  assert.deepEqual(out.connectorUpdates, { serial: 1, connectors: {} });
});
