'use strict';
/**
 * `khayt://plugin/install?id=…&version=…` on the desktop (Mac #2622): the
 * link names a connector and opens the consent sheet; it never installs.
 * Everything the sheet shows comes from Khayt's own signed index and a
 * manifest Khayt signed. Throwaway signing keys only.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const M = require('../lib/plugin-manifest.js');
require('../lib/plugin-host.js');
const U = require('../lib/plugin-update.js');
const C = require('../lib/main/connector-updates.js');
const L = require('../lib/plugin-install-link.js');
const P = require('../lib/main/plugin-install-link.js');
const VECTORS = require('./fixtures/plugin-install-link-vectors.json');

const ROOT = path.join(__dirname, '..');

/* ── The shape ─────────────────────────────────────────────────────────── */

test('only the exact shape is a link: the Mac\'s 2 accepted and 17 refused', () => {
  assert.equal(VECTORS.accepted.length, 2);
  assert.equal(VECTORS.refused.length, 17);
  for (const v of VECTORS.accepted) assert.deepEqual(L.parse(v.url), { id: v.id, version: v.version }, v.url);
  for (const url of VECTORS.refused) assert.equal(L.parse(url), null, url);
});

test('a few more ways a link is not one', () => {
  for (const url of [
    'khayt://plugin/install?id=app.khayt.samples.lamha&version=1.0.0&',
    'khayt://plugin:8080/install?id=app.khayt.samples.lamha&version=1.0.0',
    'khayt://plugin/install/?id=app.khayt.samples.lamha&version=1.0.0',
    'khayt://plugin/install?id=app.khayt.samples.lamha&version=1.0.0#',
    'khayt://plugin/install?id=app.khayt.samples.lamha&version=%zz',
    'khayt://plugin/install?id&version=1.0.0',
    null, 42, '',
  ]) assert.equal(L.parse(url), null, String(url));
  // A `+build` tag is a version: `+` is not read as a space.
  assert.deepEqual(L.parse('khayt://plugin/install?id=com.example.ship&version=1.0.0+b7'), { id: 'com.example.ship', version: '1.0.0+b7' });
});

/* ── Who may follow one ────────────────────────────────────────────────── */

const owner = { settings: {}, operators: [] };
const locked = (roleKey) => ({
  settings: { operatorLockEnabled: true, activeOperatorId: roleKey ? 'op1' : null },
  operators: roleKey ? [{ id: 'op1', roleKey }] : [{ id: 'op1', roleKey: 'owner' }],
});
const on = { connectorsOn: true, fetchOn: true, canWrite: true };

test('the gate: switched off, read-only, nobody signed in, and every lock role but the owner', () => {
  assert.equal(P.gate({ ...on, store: owner }), null, 'no lock: whoever is at the desk');
  assert.equal(P.gate({ ...on, store: locked('owner') }), null);
  assert.equal(P.gate({ ...on, connectorsOn: false, store: owner }), 'off');
  assert.equal(P.gate({ ...on, fetchOn: false, store: owner }), 'off', 'the index fetch is the connector-updates switch');
  assert.equal(P.gate({ ...on, canWrite: false, store: owner }), 'notAllowed', 'a window that cannot save');
  assert.equal(P.gate({ ...on, store: locked(null) }), 'notAllowed', 'the lock on and nobody signed in');
  assert.equal(P.gate({ ...on, store: {} }), 'notAllowed', 'no book read: refused');
  for (const role of ['manager', 'operator', 'viewer']) assert.equal(P.gate({ ...on, store: locked(role) }), 'notAllowed', role);
});

/* ── Khayt's index and manifest ────────────────────────────────────────── */

function throwawayKey(id) {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  const raw = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');
  return { id, key: raw, sign: (msg) => crypto.sign(null, Buffer.from(msg, 'utf8'), privateKey).toString('base64') };
}
const K1 = throwawayKey('test-key-1');
const K2 = throwawayKey('test-key-2');
const KEYS = [{ id: K1.id, key: K1.key }];
const NOW = Date.parse('2026-11-22T09:00:00.000Z');
const DAY = 24 * 3600 * 1000;
const LAMHA = require('../plugins/samples/lamha-shipping.json');
const MANIFEST_URL = 'https://khaytapp.com/connectors/lamha.json';
const unsignedAt = (v, extra) => { const m = Object.assign(JSON.parse(JSON.stringify(LAMHA)), { version: v }, extra || {}); delete m.signature; return m; };
const signManifest = (m, k = K1) => Object.assign({}, m, { signature: k.sign(M.canonicalJSON(m)) });
const bytesOf = (m) => Buffer.from(JSON.stringify(m), 'utf8');
const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');

function signIndex(ix, k = K1) {
  const unsigned = Object.assign({}, ix); delete unsigned.signature;
  return Object.assign({}, unsigned, { signature: { keyId: k.id, sig: k.sign(U.indexSigningMessage(unsigned)) } });
}
function indexFor(version, sha256, { revoked, id = LAMHA.id, issued = NOW - DAY, serial = 7 } = {}) {
  const row = { kind: 'connector', id, version, url: MANIFEST_URL, sha256 };
  if (revoked) row.revoked = revoked.map((v) => ({ version: v, reason: 'withdrawn' }));
  return { khaytIndex: 1, serial, issuedAt: new Date(issued).toISOString(), expires: new Date(issued + 45 * DAY).toISOString(), entries: [row] };
}
/** A fetch that serves `files` and records every address asked for. */
function fetcher(files) {
  const asked = [];
  const fn = async (url) => { asked.push(url); if (!(url in files)) throw new Error('404'); return files[url]; };
  fn.asked = asked;
  return fn;
}

const V = '1.1.1';
const GOOD = signManifest(unsignedAt(V));
const GOOD_BYTES = bytesOf(GOOD);
const link = { id: LAMHA.id, version: V };

test('the listed, signed version is offered, fetched from where the index says and nowhere else', async () => {
  const ix = signIndex(indexFor(V, sha(GOOD_BYTES)));
  const fetchBytes = fetcher({ [C.INDEX_URL]: bytesOf(ix), [MANIFEST_URL]: GOOD_BYTES });
  const r = await P.offer(link, { fetchBytes, keys: KEYS, nowMs: NOW });
  assert.equal(r.ok, true);
  assert.equal(r.manifest.id, LAMHA.id);
  assert.equal(r.manifest.version, V);
  assert.deepEqual(fetchBytes.asked, [C.INDEX_URL, MANIFEST_URL]);
});

test('an index that cannot be trusted stops before any manifest is asked for', async () => {
  const good = indexFor(V, sha(GOOD_BYTES));
  const cases = [
    ['unsigned', good],
    ['signed by a key that is not Khayt\'s', signIndex(good, K2)],
    ['expired', signIndex(indexFor(V, sha(GOOD_BYTES), { issued: NOW - 60 * DAY }))],
    ['older than this book has verified', signIndex(good)],
  ];
  for (const [why, ix] of cases) {
    const fetchBytes = fetcher({ [C.INDEX_URL]: bytesOf(ix), [MANIFEST_URL]: GOOD_BYTES });
    const r = await P.offer(link, { fetchBytes, keys: KEYS, nowMs: NOW, lastSerial: why.startsWith('older') ? 8 : null });
    assert.deepEqual(r, { ok: false, refusal: 'index' }, why);
    assert.deepEqual(fetchBytes.asked, [C.INDEX_URL], why);
  }
  // The index cannot be fetched, or is not JSON.
  assert.equal((await P.offer(link, { fetchBytes: fetcher({}), keys: KEYS, nowMs: NOW })).refusal, 'index');
  assert.equal((await P.offer(link, { fetchBytes: fetcher({ [C.INDEX_URL]: Buffer.from('<html>') }), keys: KEYS, nowMs: NOW })).refusal, 'index');
});

test('every other way it can go wrong is a refusal with no offer', async () => {
  const signed = (ix) => signIndex(ix);
  const run = async (lnk, ix, files) => {
    const fetchBytes = fetcher(Object.assign({ [C.INDEX_URL]: bytesOf(ix) }, files));
    const r = await P.offer(lnk, { fetchBytes, keys: KEYS, nowMs: NOW });
    return { r, asked: fetchBytes.asked };
  };
  const good = signed(indexFor(V, sha(GOOD_BYTES)));
  const serve = { [MANIFEST_URL]: GOOD_BYTES };

  // Not listed; another version listed; this version withdrawn — nothing downloaded.
  let x = await run({ id: 'com.example.unknown', version: '1.0.0' }, good, serve);
  assert.equal(x.r.refusal, 'unlisted'); assert.deepEqual(x.asked, [C.INDEX_URL]);
  x = await run({ id: LAMHA.id, version: '0.9.0' }, good, serve);
  assert.equal(x.r.refusal, 'otherVersion'); assert.deepEqual(x.asked, [C.INDEX_URL]);
  x = await run({ id: LAMHA.id, version: '1.2.0' }, good, serve);
  assert.equal(x.r.refusal, 'otherVersion', 'a newer version than listed is not offered either');
  x = await run(link, signed(indexFor(V, sha(GOOD_BYTES), { revoked: [V] })), serve);
  assert.equal(x.r.refusal, 'withdrawn'); assert.deepEqual(x.asked, [C.INDEX_URL]);

  // The bytes are not the ones the index promised.
  x = await run(link, signed(indexFor(V, '0'.repeat(64))), serve);
  assert.equal(x.r.refusal, 'manifest');
  // The download fails.
  x = await run(link, good, {});
  assert.equal(x.r.refusal, 'manifest');
  // A manifest Khayt did not sign, even with the right hash.
  const tampered = bytesOf(Object.assign({}, GOOD, { domains: ['evil.example'] }));
  x = await run(link, signed(indexFor(V, sha(tampered))), { [MANIFEST_URL]: tampered });
  assert.equal(x.r.refusal, 'manifest');
  const otherKey = bytesOf(signManifest(unsignedAt(V), K2));
  x = await run(link, signed(indexFor(V, sha(otherKey))), { [MANIFEST_URL]: otherKey });
  assert.equal(x.r.refusal, 'manifest');
  // The right bytes listed under another id: the link cannot be pointed at a different connector.
  const other = { id: 'com.example.other', version: V };
  x = await run(other, signed(indexFor(V, sha(GOOD_BYTES), { id: 'com.example.other' })), serve);
  assert.equal(x.r.refusal, 'manifest');
  // A signed manifest of another version, listed as this one.
  const older = bytesOf(signManifest(unsignedAt('1.0.0')));
  x = await run(link, signed(indexFor(V, sha(older))), { [MANIFEST_URL]: older });
  assert.equal(x.r.refusal, 'manifest');
  for (const r of P.REFUSALS) assert.ok(typeof r === 'string');
});

/* ── Wiring ────────────────────────────────────────────────────────────── */

test('Bed Ready never claims khayt://; Khayt claims it packaged on Windows and Linux only', () => {
  assert.deepEqual(L.protocolSchemes({ isBedReady: true, isPackaged: true, platform: 'win32' }), ['bedready']);
  assert.deepEqual(L.protocolSchemes({ isBedReady: true, isPackaged: true, platform: 'linux' }), ['bedready']);
  assert.deepEqual(L.protocolSchemes({ isBedReady: false, isPackaged: true, platform: 'win32' }), ['khayt']);
  assert.deepEqual(L.protocolSchemes({ isBedReady: false, isPackaged: true, platform: 'linux' }), ['khayt']);
  assert.deepEqual(L.protocolSchemes({ isBedReady: false, isPackaged: false, platform: 'win32' }), []);
  assert.deepEqual(L.protocolSchemes({ isBedReady: false, isPackaged: true, platform: 'darwin' }), [], 'the native Mac app owns it there');
  const main = fs.readFileSync(path.join(ROOT, 'main.js'), 'utf8');
  // Every registration goes through protocolSchemes: no literal scheme is claimed beside it.
  const calls = [...main.matchAll(/setAsDefaultProtocolClient\(([^)]*)\)/g)].map((m) => m[1].trim());
  assert.deepEqual(calls, ['scheme']);
  assert.match(main, /PluginInstallLink\.protocolSchemes\(\{ isBedReady, isPackaged: app\.isPackaged, platform: process\.platform \}\)/);
  // And the Bed Ready flavour drops a khayt:// link handed to it anyway.
  assert.match(main, /function receiveKhaytUrl\(url\) \{\n\s+if \(isBedReady\) return;/);
});

test('the window takes the offer through the same door as a hand install', () => {
  const src = fs.readFileSync(path.join(ROOT, 'renderer/plugins.js'), 'utf8');
  const fn = src.slice(src.indexOf('async function takePluginInstallLink'), src.indexOf('let _pluginInstallLinksWatched'));
  assert.match(fn, /openSettingsSection\('connections'\)/);
  assert.match(fn, /installPluginManifest\(r\.manifest\)/, 'the consent sheet, main\'s check again, nothing stored until Install');
  assert.doesNotMatch(fn, /saveAll|withEntry/, 'the link itself writes nothing');
  require('../renderer/locales/en.js');
  const words = global.KhaytLocales.en;
  for (const r of P.REFUSALS) assert.ok(words['plg.pil_' + r], 'a sentence for ' + r);
});

test('packaging (review at release): khayt:// declared for Windows (NSIS + appx) and Linux only; never macOS, never Bed Ready', () => {
  const fs = require('fs'), path = require('path');
  const root = path.join(__dirname, '..');
  const b = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8')).build;
  const schemes = (x) => (Array.isArray(x) ? x : []).flatMap((p) => p.schemes || []);
  assert.deepEqual(schemes(b.win && b.win.protocols), ['khayt']);
  assert.deepEqual(schemes(b.linux && b.linux.protocols), ['khayt']);
  assert.equal(b.protocols, undefined, 'no top-level entry: it would register macOS too');
  assert.deepEqual(schemes(b.mac && b.mac.protocols), []);
  const br = require(path.join(root, 'electron-builder.bedready.js'));
  const cfg = br && br.default ? br.default : br;
  assert.deepEqual(schemes(cfg.protocols), ['bedready']);
  assert.deepEqual(schemes(cfg.win && cfg.win.protocols), []);
  assert.deepEqual(schemes(cfg.linux && cfg.linux.protocols), []);
});
