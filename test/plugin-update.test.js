'use strict';
/**
 * Connector updates (lib/plugin-update.js) — Turki's rules of Nov 10:
 * same permissions → installs by itself; more → waits for a yes while the old
 * version keeps running; a withdrawn version is paused everywhere; a plugin
 * never updates by itself; an index that cannot be trusted changes NOTHING.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const M = require('../lib/plugin-manifest.js');
require('../lib/plugin-host.js');
const U = require('../lib/plugin-update.js');

const NOW = Date.parse('2026-11-12T09:00:00.000Z');
const DAY = 24 * 3600 * 1000;
const LAMHA = require('../plugins/samples/lamha-shipping.json');

const at = (v) => Object.assign(JSON.parse(JSON.stringify(LAMHA)), { version: v });
/** Lamha as it would be without the customer's email: the narrower version
 *  a shop agreed to, before one that asks for more. */
const narrow = (v) => JSON.parse(JSON.stringify(at(v)).split('"{customer.email}"').join('""'));
function installedNarrow() {
  const m = narrow('1.0.0');
  return { id: m.id, version: '1.0.0', enabled: true, manifest: m, granted: M.grantFor(m), config: Object.assign({}, CONFIG) };
}
const CONFIG = { senderName: 'Athar', senderPhone: '0500000000', senderCity: 'Riyadh', senderAddress: 'X', carrierId: String(LAMHA.settings.find((s) => s.key === 'carrierId').options[0].value) };
/** Installed at 1.0.0, granted exactly that. */
function installed(version = '1.0.0', grantOverride) {
  const m = at(version);
  return { id: m.id, version, enabled: true, manifest: m, granted: grantOverride || M.grantFor(m), config: Object.assign({}, CONFIG) };
}
function book(entry, updates) {
  const s = { currency: 'SAR', plugins: [entry || installed()] };
  if (updates) s.connectorUpdates = updates;
  return s;
}
function row(version, extra) {
  return Object.assign({ kind: 'connector', id: LAMHA.id, version, url: `https://khaytapp.com/connectors/${LAMHA.id}/${version}.json`,
                         sha256: 'a'.repeat(64), size: 1000, requires: { schema: 1, mac: '4.0.0-beta.33', desktop: '4.9.0', ios: '202611101200' } }, extra || {});
}
/** `after` is `before` with nothing changed but the remembered serial, which
 *  it returns. Throws when anything else moved. */
function onlySerial(before, after) {
  assert.notEqual(after, before, 'a new object: the one passed in is never edited');
  const a = JSON.parse(JSON.stringify(after)); const b = JSON.parse(JSON.stringify(before));
  const serial = a.connectorUpdates.serial;
  if (b.connectorUpdates) { a.connectorUpdates.serial = b.connectorUpdates.serial; if (b.connectorUpdates.serial === undefined) delete a.connectorUpdates.serial; }
  else { assert.deepEqual(a.connectorUpdates, { connectors: {}, serial }); delete a.connectorUpdates; }
  assert.deepEqual(a, b, 'nothing but the serial');
  return serial;
}
function index(rows, extra) {
  return Object.assign({ khaytIndex: 1, serial: 7, issuedAt: new Date(NOW - DAY).toISOString(),
                         expires: new Date(NOW + 44 * DAY).toISOString(), entries: rows,
                         signature: { keyId: 'khayt-2026-11', sig: 'x' } }, extra || {});
}
const CTX = { signedBy: 'khayt-2026-11', nowMs: NOW, platform: 'mac', appVersion: '4.0.0-beta.33', schema: 1 };

/* ── versions ─────────────────────────────────────────────────────────── */

test('versions compare field by field, never as strings', () => {
  assert.equal(U.compareVersions('1.10.0', '1.9.9'), 1);
  assert.equal(U.compareVersions('1.1.1', '1.1.1'), 0);
  assert.equal(U.compareVersions('1.1', '1.1.0'), 0);
  assert.equal(U.compareVersions('1.1.0-beta.2', '1.1.0'), -1, 'a pre-release is older than its release');
  assert.equal(U.compareVersions('1.1.0-beta.10', '1.1.0-beta.9'), 1);
  assert.equal(U.compareVersions('4.0.0-beta.33', '4.0.0-beta.32'), 1);
  assert.equal(U.compareVersions('202611101200', '202611091953'), 1, "the phone's build number");
});

/* ── the index, and failing safe ──────────────────────────────────────── */

test('the index signature covers a context prefix, so a manifest signature cannot pass for it', () => {
  const ix = index([row('1.1.1')]);
  const msg = U.indexSigningMessage(ix);
  assert.ok(msg.startsWith('khayt-index-v1\n'));
  assert.ok(!msg.includes('"signature"'));
  assert.notEqual(msg, M.canonicalJSON(ix));
});

const BAD = {
  unreadable: [
    ['not an object', () => 'nope'],
    ['wrong format', () => index([row('1.1.1')], { khaytIndex: 2 })],
    ['no entries', () => index(null)],
    ['bad serial', () => index([row('1.1.1')], { serial: 0 })],
    ['bad dates', () => index([row('1.1.1')], { expires: 'soon' })],
    ['expires before issued', () => index([row('1.1.1')], { expires: new Date(NOW - 2 * DAY).toISOString() })],
    ['a row with an http url', () => index([row('1.1.1', { url: 'http://khaytapp.com/x.json' })])],
    ['a row with a short sha256', () => index([row('1.1.1', { sha256: 'abc' })])],
  ],
  unsigned: [['no verified signer', () => index([row('1.1.1')]), { signedBy: null }]],
  old_serial: [['an older serial than one applied', () => index([row('1.1.1')], { serial: 6 })]],
  expired: [['past its expiry', () => index([row('1.1.1')], { expires: new Date(NOW - 1).toISOString(), issuedAt: new Date(NOW - 46 * DAY).toISOString() })]],
  from_future: [['issued two days ahead of this clock', () => index([row('1.1.1')], { issuedAt: new Date(NOW + 2 * DAY).toISOString(), expires: new Date(NOW + 47 * DAY).toISOString() })]],
};

for (const [reason, cases] of Object.entries(BAD)) {
  for (const [name, make, ctxOver] of cases) {
    test(`an index that is ${name} fails safe (${reason}): the book is the same object, byte for byte`, () => {
      // A book that WOULD change on a good index: 1.0.0 is revoked and 1.1.1 is there.
      const settings = book(installed('1.0.0'), { serial: 7, connectors: {} });
      const before = JSON.stringify(settings);
      const ix = make();
      if (ix && ix.entries) ix.entries.forEach((r) => { r.revoked = [{ version: '1.0.0', reason: 'bad' }]; });
      const ctx = Object.assign({}, CTX, ctxOver || {});
      assert.equal(U.checkIndex(ix, Object.assign({ lastSerial: 7 }, ctx)).reason, reason);
      assert.deepEqual(U.fetchesFor(settings, ix, ctx), [], 'nothing is downloaded');
      const r = U.applyIndex(settings, ix, ctx, { [LAMHA.id]: at('1.1.1') });
      assert.equal(r.ok, false);
      assert.equal(r.reason, reason);
      assert.equal(r.settings, settings, 'the very same object');
      assert.equal(r.changed, false);
      assert.deepEqual(r.notes, []);
      assert.equal(JSON.stringify(settings), before, 'not a byte moved — no update, no revocation, no serial');
      assert.equal(settings.plugins[0].enabled, true, 'the connector keeps running');
    });
  }
}

test('the same serial again is the same index, not a replay', () => {
  assert.equal(U.checkIndex(index([row('1.1.1')]), Object.assign({ lastSerial: 7 }, CTX)).ok, true);
});

test('a revocation applied from an earlier good index stays when a later index is bad', () => {
  let s = book(installed('1.0.0'));
  s = U.applyIndex(s, index([row('1.0.0', { revoked: [{ version: '1.0.0', reason: 'Reports a refused order as sent.' }] })]), CTX, {}).settings;
  assert.equal(s.plugins[0].enabled, false);
  const r = U.applyIndex(s, index([row('1.0.0')], { expires: new Date(NOW - 1).toISOString(), issuedAt: new Date(NOW - 46 * DAY).toISOString() }), CTX, {});
  assert.equal(r.settings, s);
  assert.equal(U.runnable(s.plugins[0], U.stateOf(s, LAMHA.id)).why, 'revoked');
});

/* ── every plan ───────────────────────────────────────────────────────── */

test('none: not listed, not newer, a downgrade, skipped, already offered, or withdrawn itself', () => {
  const e = installed('1.1.1');
  assert.equal(U.planUpdate(e, {}, null, CTX).plan, 'none');
  assert.equal(U.planUpdate(e, {}, row('1.1.1'), CTX).reason, 'current');
  assert.equal(U.planUpdate(e, {}, row('1.0.0'), CTX).reason, 'current', 'never a downgrade');
  assert.equal(U.planUpdate(e, { skipped: ['1.2.0'] }, row('1.2.0'), CTX).reason, 'skipped');
  assert.equal(U.planUpdate(e, { pending: { version: '1.2.0' } }, row('1.2.0'), CTX).reason, 'offered');
  assert.equal(U.planUpdate(e, {}, row('1.2.0', { revoked: [{ version: '1.2.0', reason: 'x' }] }), CTX).reason, 'withdrawn');
});

test('blocked: a newer schema, or a newer app on THIS platform', () => {
  const e = installed('1.0.0');
  assert.deepEqual(U.planUpdate(e, {}, row('1.1.1', { requires: { schema: 2 } }), CTX).needs, { schema: 2 });
  const mac = U.planUpdate(e, {}, row('1.1.1', { requires: { mac: '4.0.0-beta.34' } }), CTX);
  assert.equal(mac.plan, 'blocked');
  assert.deepEqual(mac.needs, { app: '4.0.0-beta.34' });
  assert.equal(U.planUpdate(e, {}, row('1.1.1', { requires: { ios: '209901010000' } }), CTX).plan, 'fetch', "another platform's minimum is not this one's");
});

test('fetch: newer and runnable here — the url and sha256 to check', () => {
  const p = U.planUpdate(installed('1.0.0'), {}, row('1.1.1'), CTX);
  assert.deepEqual([p.plan, p.version, p.sha256], ['fetch', '1.1.1', 'a'.repeat(64)]);
});

test('auto: nothing beyond the grant; needs_setup: same grant, a new required setting', () => {
  const e = installed('1.0.0');
  assert.equal(U.planWithManifest(e, at('1.1.1'), row('1.1.1')).plan, 'auto');
  const more = at('1.1.1');
  more.settings = more.settings.concat([{ key: 'senderEmail', type: 'text', required: true, label: { en: 'Sender email' } }]);
  const v = M.validateManifest(more);
  assert.ok(v.ok, v.errors.join('; '));
  const q = U.planWithManifest(e, more, row('1.1.1'));
  assert.equal(q.plan, 'needs_setup');
  assert.deepEqual(q.missing, ['senderEmail']);
});

test('consent: the new version asks for a field the shop never granted', () => {
  assert.equal(M.checkEntry(installedNarrow()).ok, true);
  const q = U.planWithManifest(installedNarrow(), at('1.1.1'), row('1.1.1'));
  assert.equal(q.plan, 'consent');
  assert.deepEqual(q.diff.fields, ['customer.email']);
});

test('a PLUGIN never updates by itself, even asking for nothing new (Turki, Nov 10)', () => {
  const q = U.planWithManifest(installed('1.0.0'), at('1.1.1'), row('1.1.1', { kind: 'plugin' }));
  assert.equal(q.plan, 'consent');
  assert.equal(q.diff.widened, false);
  // An addon follows the connector rules.
  assert.equal(U.planWithManifest(installed('1.0.0'), at('1.1.1'), row('1.1.1', { kind: 'addon' })).plan, 'auto');
});

test('a manifest that is not the one promised, or does not validate here, is not applied', () => {
  assert.equal(U.planWithManifest(installed('1.0.0'), at('1.2.0'), row('1.1.1')).reason, 'mismatch');
  const other = Object.assign(at('1.1.1'), { id: 'app.other' });
  assert.equal(U.planWithManifest(installed('1.0.0'), other, row('1.1.1')).reason, 'mismatch');
  const broken = Object.assign(at('1.1.1'), { domains: [] });
  assert.equal(U.planWithManifest(installed('1.0.0'), broken, row('1.1.1')).reason, 'invalid');
});

test('revoke: the withdrawn version is paused by its own switch, so old builds stop too', () => {
  const p = U.planUpdate(installed('1.0.0'), {}, row('1.0.0', { revoked: [{ version: '1.0.0', reason: '  Reports a refused\norder as sent. ' }] }), CTX);
  assert.deepEqual([p.plan, p.reason], ['revoke', 'Reports a refused order as sent.']);
});

/* ── a whole pass over the book ───────────────────────────────────────── */

test('an automatic update: new manifest, the SAME grant, the old one kept for Revert, a quiet note', () => {
  const s0 = book();
  const ix = index([row('1.1.1')]);
  assert.deepEqual(U.fetchesFor(s0, ix, CTX).map((f) => f.version), ['1.1.1']);
  const r = U.applyIndex(s0, ix, CTX, { [LAMHA.id]: at('1.1.1') });
  assert.equal(r.ok, true);
  assert.equal(r.changed, true);
  const e = r.settings.plugins[0];
  assert.equal(e.version, '1.1.1');
  assert.equal(e.manifest.version, '1.1.1');
  assert.deepEqual(e.granted, s0.plugins[0].granted, 'the grant the shop gave, untouched');
  assert.deepEqual(e.config, CONFIG);
  const st = U.stateOf(r.settings, LAMHA.id);
  assert.equal(st.previous.version, '1.0.0');
  assert.equal(st.updatedFrom, '1.0.0');
  assert.equal(st.updatedAt, new Date(NOW).toISOString());
  assert.equal(r.settings.connectorUpdates.serial, 7);
  assert.deepEqual(r.notes, [{ id: LAMHA.id, kind: 'updated', from: '1.0.0', to: '1.1.1', missing: [] }]);
  assert.equal(s0.plugins[0].version, '1.0.0', 'the book passed in is not edited');
});

test('every entry it writes is one EVERY older build accepts — only the keys they know', () => {
  const OLD_KEYS = ['id', 'version', 'enabled', 'manifest', 'granted', 'config', 'secrets'];
  const cases = [
    U.applyIndex(book(), index([row('1.1.1')]), CTX, { [LAMHA.id]: at('1.1.1') }).settings,
    U.applyIndex(book(installedNarrow()), index([row('1.1.1')]), CTX, { [LAMHA.id]: at('1.1.1') }).settings,
    U.applyIndex(book(), index([row('1.0.0', { revoked: [{ version: '1.0.0', reason: 'x' }] })]), CTX, {}).settings,
  ];
  for (const s of cases) {
    for (const e of s.plugins) {
      assert.deepEqual(Object.keys(e).filter((k) => !OLD_KEYS.includes(k)), []);
      assert.equal(M.checkEntry(e).ok, true, M.checkEntry(e).errors.join('; '));
    }
  }
});

test('a consent: the old version keeps running, the new one waits beside it; Not now asks again only for a newer one', () => {
  const s0 = book(installedNarrow());
  const r = U.applyIndex(s0, index([row('1.1.1')]), CTX, { [LAMHA.id]: at('1.1.1') });
  const e = r.settings.plugins[0];
  assert.equal(e.version, '1.0.0', 'unchanged: it keeps running');
  assert.equal(U.runnable(e, U.stateOf(r.settings, LAMHA.id)).which, 'current');
  const st = U.stateOf(r.settings, LAMHA.id);
  assert.equal(st.pending.version, '1.1.1');
  assert.deepEqual(st.pending.diff.fields, ['customer.email']);
  assert.equal(r.notes[0].kind, 'pending');
  // Tomorrow, the same index: nothing new to download, the badge stays.
  assert.deepEqual(U.fetchesFor(r.settings, index([row('1.1.1')]), CTX), []);
  const again = U.applyIndex(r.settings, index([row('1.1.1')]), CTX, {});
  assert.equal(again.settings, r.settings);
  // A newer version is offered.
  assert.deepEqual(U.fetchesFor(r.settings, index([row('1.2.0')], { serial: 8 }), CTX).map((f) => f.version), ['1.2.0']);
});

test('agreeing installs exactly what was shown, keeps the old one, and clears the badge', () => {
  const s1 = U.applyIndex(book(installedNarrow()), index([row('1.1.1')]), CTX, { [LAMHA.id]: at('1.1.1') }).settings;
  const r = U.agree(s1, LAMHA.id, { nowMs: NOW + 1000 });
  assert.equal(r.ok, true);
  const e = r.settings.plugins[0];
  assert.equal(e.version, '1.1.1');
  assert.deepEqual(e.granted, M.grantFor(at('1.1.1')));
  assert.deepEqual(e.config, CONFIG);
  const st = U.stateOf(r.settings, LAMHA.id);
  assert.equal(st.pending, undefined);
  assert.equal(st.previous.version, '1.0.0');
  assert.equal(U.agree(r.settings, LAMHA.id, {}).ok, false, 'nothing left to agree to');
});

test('Revert goes back, and that version is never installed by itself again — a newer one is', () => {
  const s1 = U.applyIndex(book(), index([row('1.1.1')]), CTX, { [LAMHA.id]: at('1.1.1') }).settings;
  const r = U.revert(s1, LAMHA.id);
  assert.equal(r.ok, true);
  assert.equal(r.settings.plugins[0].version, '1.0.0');
  assert.deepEqual(r.settings.plugins[0].granted, M.grantFor(at('1.0.0')));
  const st = U.stateOf(r.settings, LAMHA.id);
  assert.deepEqual(st.skipped, ['1.1.1']);
  assert.equal(st.previous, undefined);
  assert.deepEqual(U.fetchesFor(r.settings, index([row('1.1.1')]), CTX), []);
  assert.deepEqual(U.fetchesFor(r.settings, index([row('1.2.0')], { serial: 8 }), CTX).map((f) => f.version), ['1.2.0']);
  assert.equal(U.revert(r.settings, LAMHA.id).ok, false, 'nothing to go back to');
});

test('a revoked version pauses with its reason; the fixed version then installs and the switch comes back', () => {
  const rev = { revoked: [{ version: '1.0.0', reason: 'Reports a refused order as sent.' }] };
  const r1 = U.applyIndex(book(), index([row('1.0.0', rev)]), CTX, {});
  const e1 = r1.settings.plugins[0];
  assert.equal(e1.enabled, false, "the entry's own switch: old builds honour it");
  const st = U.stateOf(r1.settings, LAMHA.id);
  assert.deepEqual([st.revoked.version, st.revoked.reason, st.revoked.wasEnabled], ['1.0.0', 'Reports a refused order as sent.', true]);
  assert.deepEqual(U.runnable(e1, st), { run: false, which: null, why: 'revoked', reason: 'Reports a refused order as sent.' });
  assert.equal(r1.notes[0].kind, 'revoked');
  // The same index again: not revoked twice.
  assert.equal(U.applyIndex(r1.settings, index([row('1.0.0', rev)]), CTX, {}).settings, r1.settings);
  // 1.1.1 arrives in the same pass as the revocation of 1.0.0.
  const r2 = U.applyIndex(book(), index([row('1.1.1', rev)]), CTX, { [LAMHA.id]: at('1.1.1') });
  const e2 = r2.settings.plugins[0];
  assert.deepEqual([e2.version, e2.enabled], ['1.1.1', true]);
  assert.equal(U.stateOf(r2.settings, LAMHA.id).revoked, undefined);
  assert.deepEqual(r2.notes.map((n) => n.kind), ['revoked', 'updated']);
  // A connector the shop had switched off stays off after the fix.
  const off = installed('1.0.0'); off.enabled = false;
  const r3 = U.applyIndex(book(off), index([row('1.1.1', rev)]), CTX, { [LAMHA.id]: at('1.1.1') });
  assert.equal(r3.settings.plugins[0].enabled, false);
});

// Nov 11: this and the next test used to pin "nothing is written at all". The
// promise is narrower now — nothing but the index's serial, and only when it
// rose — because a serial that is not remembered can be replayed (below).
test('blocked is told, and nothing is written but the serial', () => {
  const s0 = book();
  const r = U.applyIndex(s0, index([row('1.1.1', { requires: { mac: '4.0.0-beta.40' } })]), CTX, {});
  assert.deepEqual(onlySerial(s0, r.settings), 7);
  assert.deepEqual(r.notes, [{ id: LAMHA.id, kind: 'blocked', from: '1.0.0', to: '1.1.1', needs: { app: '4.0.0-beta.40' } }]);
});

test('a download that failed is simply tried again: nothing written', () => {
  const s0 = book();
  const r = U.applyIndex(s0, index([row('1.1.1')]), CTX, {});
  assert.deepEqual(onlySerial(s0, r.settings), 7);
  assert.equal(r.changed, true, 'the serial is a write');
  assert.deepEqual(U.fetchesFor(r.settings, index([row('1.1.1')]), CTX).map((f) => f.version), ['1.1.1'], 'and it is asked for again');
  // The same index a second time: now truly nothing.
  const again = U.applyIndex(r.settings, index([row('1.1.1')]), CTX, {});
  assert.equal(again.settings, r.settings);
  assert.equal(again.changed, false);
});

test('a device too old to read the new manifest runs the previous one', () => {
  const s1 = U.applyIndex(book(), index([row('1.1.1')]), CTX, { [LAMHA.id]: at('1.1.1') }).settings;
  const e = JSON.parse(JSON.stringify(s1.plugins[0]));
  e.manifest.khayt = 99;  // what an older validator would refuse
  e.manifest.version = e.version;
  const got = U.runnable(e, U.stateOf(s1, LAMHA.id));
  assert.deepEqual([got.run, got.which, got.manifest.version], [true, 'previous', '1.0.0']);
  assert.equal(U.runnable(e, {}).why, 'invalid', 'with no previous, nothing runs');
});

test('checkEntry takes an `ext` object from now on, so the next shape change needs no dance', () => {
  const e = installed('1.0.0');
  assert.equal(M.checkEntry(Object.assign({}, e, { ext: { anything: 1 } })).ok, true);
  assert.equal(M.checkEntry(Object.assign({}, e, { ext: 'x' })).ok, false);
  assert.equal(M.checkEntry(Object.assign({}, e, { previous: {} })).ok, false, 'still strict about everything else');
});

test("the fixed version brings the switch back only if the shop had it on — its own choice while revoked is kept", () => {
  const rev = { revoked: [{ version: '1.0.0', reason: 'Reports a refused order as sent.' }] };
  const revoked = U.applyIndex(book(), index([row('1.0.0', rev)]), CTX, {}).settings;
  // (a) On before the revocation, left alone: back on after the fix.
  const fixedA = U.applyIndex(revoked, index([row('1.1.1', rev)], { serial: 8 }), CTX, { [LAMHA.id]: at('1.1.1') }).settings;
  assert.equal(fixedA.plugins[0].enabled, true);
  // (b) On before, but the shop switched it OFF while it was revoked: stays off.
  const off = U.setSwitch(revoked, LAMHA.id, false);
  assert.equal(off.revoked, true);
  assert.equal(off.settings.plugins[0].enabled, false, 'still off for old builds');
  assert.equal(U.stateOf(off.settings, LAMHA.id).revoked.wasEnabled, false);
  const fixedB = U.applyIndex(off.settings, index([row('1.1.1', rev)], { serial: 8 }), CTX, { [LAMHA.id]: at('1.1.1') }).settings;
  assert.equal(fixedB.plugins[0].enabled, false);
  // Switching it on while revoked does not run it, and is what the fix restores.
  const on = U.setSwitch(off.settings, LAMHA.id, true);
  assert.equal(on.settings.plugins[0].enabled, false);
  assert.equal(U.runnable(on.settings.plugins[0], U.stateOf(on.settings, LAMHA.id)).why, 'revoked');
  const fixedC = U.applyIndex(on.settings, index([row('1.1.1', rev)], { serial: 8 }), CTX, { [LAMHA.id]: at('1.1.1') }).settings;
  assert.equal(fixedC.plugins[0].enabled, true);
  // Not revoked: the switch is just the switch.
  assert.equal(U.setSwitch(book(), LAMHA.id, false).settings.plugins[0].enabled, false);
});

// ── A field re-routed to another host is asking for more (review, Nov 10) ──
test('same fields and same hosts, but a field now goes to the other host: consent, never automatic', () => {
  const PM = require('../lib/plugin-manifest.js');
  const base = (toA, toB, authHost) => ({
    khayt: { manifest: 1 }, id: 'app.test.route', name: { en: 'Route' }, publisher: 'T', version: '1.0.0',
    domains: ['a.example.com', 'b.example.com'],
    secrets: [{ name: 'key', label: { en: 'Key' }, kind: 'token' }],
    actions: [
      { id: 'one', label: { en: 'One' }, placement: 'order', kind: 'post', url: 'https://a.example.com/x',
        ...(authHost === 'a' ? { auth: { header: 'X-K', secret: 'key' } } : {}),
        body: { format: 'json-template', template: toA } },
      { id: 'two', label: { en: 'Two' }, placement: 'order', kind: 'post', url: 'https://b.example.com/y',
        ...(authHost === 'b' ? { auth: { header: 'X-K', secret: 'key' } } : {}),
        body: { format: 'json-template', template: toB } },
    ],
  });
  const v1 = base({ n: '{customer.name}', p: '{customer.phone}' }, { i: '{order.id}' }, 'a');
  const v2 = base({ i: '{order.id}' }, { n: '{customer.name}', p: '{customer.phone}' }, 'a');
  const granted = PM.grantFor(v1);
  assert.deepEqual(PM.diffPermissions(granted, v1).widened, false, 'the version agreed to asks for nothing more');
  const moved = PM.diffPermissions(granted, v2);
  assert.deepEqual([moved.fields, moved.domains], [[], []], 'no new field and no new host');
  assert.equal(moved.widened, true);
  assert.ok(moved.routes.includes('b.example.com customer.phone'));
  // The key sent to the other host is the same kind of move.
  const keyMoved = PM.diffPermissions(granted, base({ n: '{customer.name}', p: '{customer.phone}' }, { i: '{order.id}' }, 'b'));
  assert.deepEqual(keyMoved.routes, ['b.example.com secret:key']);
  assert.equal(keyMoved.widened, true);
  // Sending LESS is never a reason to ask.
  assert.equal(PM.diffPermissions(granted, base({ n: '{customer.name}' }, { i: '{order.id}' }, 'a')).widened, false);
  // A grant from before pairs were kept allowed every field to every host it lists: nothing installed is paused.
  const old = { version: granted.version, fields: granted.fields, domains: granted.domains, scopes: granted.scopes };
  assert.equal(PM.diffPermissions(old, v2).widened, false);
  assert.equal(PM.diffPermissions(old, v1).widened, false);
});

// ── A grant made before pairs were kept (Lamha 1.1.1 on beta.33) ──────────
test('a grant with no `routes` is consent to what it lists: nothing asks again, and the next update is automatic', () => {
  // What beta.33's "Agree and install" wrote: version, fields, domains, scopes.
  const full = M.grantFor(at('1.1.1'));
  const legacy = { version: full.version, fields: full.fields, domains: full.domains, scopes: full.scopes };
  const entry = installed('1.1.1', legacy);
  // (a) The installed version is not paused, not pending, and still runs.
  const check = M.checkEntry(entry);
  assert.deepEqual([check.ok, check.paused], [true, false]);
  const diff = M.diffPermissions(legacy, entry.manifest);
  assert.deepEqual([diff.widened, diff.routes], [false, []]);
  const s0 = book(entry);
  assert.deepEqual(U.runnable(entry, U.stateOf(s0, LAMHA.id)).which, 'current');
  // An index that lists the installed version changes nothing but the serial
  // it remembers (Nov 11; this line used to say "nothing at all").
  const same = U.applyIndex(s0, index([row('1.1.1')]), CTX, {});
  assert.deepEqual([same.ok, same.notes], [true, []]);
  assert.equal(onlySerial(s0, same.settings), 7);
  assert.deepEqual(same.settings.plugins[0], entry, 'the entry and its grant are not touched');
  // (b) A later version that sends nothing new installs by itself.
  assert.equal(U.planWithManifest(entry, at('1.1.2'), row('1.1.2')).plan, 'auto');
  const r = U.applyIndex(s0, index([row('1.1.2')]), CTX, { [LAMHA.id]: at('1.1.2') });
  assert.deepEqual(r.notes.map((n) => n.kind), ['updated']);
  assert.equal(r.settings.plugins[0].version, '1.1.2');
  assert.equal(U.stateOf(r.settings, LAMHA.id).pending, undefined, 'no badge');
  // Nov 11: this used to say the grant comes through untouched. It now gains
  // its pairs — what the installed 1.1.1 really sent — so it is read as
  // "every field to every host" only this once. Nothing else in it moves.
  const healed = r.settings.plugins[0].granted;
  assert.deepEqual(healed.routes, M.permissionsOf(at('1.1.1')).routes);
  assert.deepEqual(Object.assign({}, healed, { routes: undefined }), Object.assign({}, legacy, { routes: undefined }), 'what the shop gave, and no more');
  assert.deepEqual(healed, Object.assign({}, full, { version: '1.1.1' }), 'the same grant "Agree and install" writes today');
  assert.deepEqual(M.checkEntry(r.settings.plugins[0]), { ok: true, errors: [], paused: false });
  assert.deepEqual(U.stateOf(r.settings, LAMHA.id).previous.granted, legacy, 'Revert puts back exactly what was there');
  // A field the shop never agreed to still asks, as it would with pairs.
  const narrowGrant = (() => { const g = M.grantFor(narrow('1.1.1')); return { version: g.version, fields: g.fields, domains: g.domains, scopes: g.scopes }; })();
  const narrowEntry = Object.assign(installed('1.1.1', narrowGrant), { manifest: narrow('1.1.1') });
  assert.equal(U.planWithManifest(narrowEntry, at('1.1.2'), row('1.1.2')).plan, 'consent');
});

/* ── The three blockers of the Nov 11 review ──────────────────────────── */

const REV = { revoked: [{ version: '1.0.0', reason: 'Reports a refused order as sent.' }] };

test('a withdrawn version is not kept when its fix installs: no Revert, no fallback, by either road', () => {
  // Revoked first, the fix a day later (the record is in the book by then).
  const revoked = U.applyIndex(book(), index([row('1.0.0', REV)]), CTX, {}).settings;
  const fixed = U.applyIndex(revoked, index([row('1.1.1', REV)], { serial: 8 }), CTX, { [LAMHA.id]: at('1.1.1') }).settings;
  // Revoked and fixed in one pass.
  const once = U.applyIndex(book(), index([row('1.1.1', REV)]), CTX, { [LAMHA.id]: at('1.1.1') }).settings;
  // A fix that asks for more: revoked, then agreed to.
  const waiting = U.applyIndex(book(installedNarrow()), index([row('1.1.1', REV)]), CTX, { [LAMHA.id]: at('1.1.1') }).settings;
  assert.equal(U.runnable(waiting.plugins[0], U.stateOf(waiting, LAMHA.id)).why, 'revoked', 'paused while it waits');
  const agreed = U.agree(waiting, LAMHA.id, { nowMs: NOW }).settings;
  for (const [name, s] of [['auto, two passes', fixed], ['auto, one pass', once], ['agreed', agreed]]) {
    const st = U.stateOf(s, LAMHA.id);
    assert.equal(s.plugins[0].version, '1.1.1', name);
    assert.equal(st.previous, undefined, `${name}: the withdrawn 1.0.0 is not kept`);
    assert.equal(st.revoked, undefined, name);
    assert.equal(st.updatedFrom, '1.0.0', `${name}: the note still says what happened`);
    assert.equal(st.previousWithdrawn, '1.0.0', `${name}: and WHY there is no Revert is written down`);
    assert.equal(JSON.stringify(s).includes('"version":"1.0.0","manifest"'), false, `${name}: its manifest is nowhere in the book`);
    const back = U.revert(s, LAMHA.id);
    assert.equal(back.ok, false, `${name}: Revert is unavailable`);
    assert.equal(back.settings, s);
    // A device that cannot read 1.1.1 runs NOTHING rather than the withdrawn one.
    const e = JSON.parse(JSON.stringify(s.plugins[0]));
    e.manifest.khayt = 99;
    assert.deepEqual(U.runnable(e, st), { run: false, which: null, why: 'invalid' }, name);
  }
});

test('a kept or a waiting version the index later withdraws is dropped', () => {
  // 1.0.0 → 1.1.1 by itself: 1.0.0 is kept. Then Khayt withdraws 1.0.0.
  const s1 = U.applyIndex(book(), index([row('1.1.1')]), CTX, { [LAMHA.id]: at('1.1.1') }).settings;
  assert.equal(U.stateOf(s1, LAMHA.id).previous.version, '1.0.0');
  const r = U.applyIndex(s1, index([row('1.1.1', REV)], { serial: 8 }), CTX, {});
  assert.equal(r.changed, true);
  assert.equal(U.stateOf(r.settings, LAMHA.id).previous, undefined);
  assert.equal(U.stateOf(r.settings, LAMHA.id).previousWithdrawn, '1.0.0', 'the device can say which version was withdrawn');
  assert.equal(U.stateOf(s1, LAMHA.id).previousWithdrawn, undefined, 'an ordinary update, Revert on offer: no such note');
  assert.equal(U.revert(r.settings, LAMHA.id).ok, false);
  assert.deepEqual([r.settings.plugins[0].version, r.settings.plugins[0].enabled], ['1.1.1', true], 'the version in use is not the withdrawn one: it keeps running');
  // A consent waiting for 1.1.1, then 1.1.1 is withdrawn before the shop answers.
  const w = U.applyIndex(book(installedNarrow()), index([row('1.1.1')]), CTX, { [LAMHA.id]: at('1.1.1') }).settings;
  assert.equal(U.stateOf(w, LAMHA.id).pending.version, '1.1.1');
  const gone = U.applyIndex(w, index([row('1.1.1', { revoked: [{ version: '1.1.1', reason: 'x' }] })], { serial: 8 }), CTX, {}).settings;
  assert.equal(U.stateOf(gone, LAMHA.id).pending, undefined);
  assert.equal(U.agree(gone, LAMHA.id, {}).ok, false, 'nothing withdrawn can be agreed to');
  assert.equal(gone.plugins[0].version, '1.0.0');
});

test('revert and runnable refuse a previous version recorded as withdrawn, however it got there', () => {
  // A book in the shape the first version of this file wrote: 1.1.1 current,
  // the withdrawn 1.0.0 kept beside it, the record still there.
  const s1 = U.applyIndex(book(), index([row('1.1.1')]), CTX, { [LAMHA.id]: at('1.1.1') }).settings;
  const bad = JSON.parse(JSON.stringify(s1));
  bad.connectorUpdates.connectors[LAMHA.id].revoked = { version: '1.0.0', reason: 'x', at: new Date(NOW).toISOString(), wasEnabled: true };
  const r = U.revert(bad, LAMHA.id);
  assert.deepEqual([r.ok, r.reason], [false, 'revoked']);
  assert.equal(r.settings, bad);
  const e = JSON.parse(JSON.stringify(bad.plugins[0]));
  e.manifest.khayt = 99;
  assert.equal(U.runnable(e, U.stateOf(bad, LAMHA.id)).run, false);
});

test('reverting away from a withdrawn version brings the switch back as the shop had it', () => {
  // 1.0.0 → 1.1.1 by itself, then 1.1.1 is withdrawn with no fix yet.
  const s1 = U.applyIndex(book(), index([row('1.1.1')]), CTX, { [LAMHA.id]: at('1.1.1') }).settings;
  const s2 = U.applyIndex(s1, index([row('1.1.1', { revoked: [{ version: '1.1.1', reason: 'x' }] })], { serial: 8 }), CTX, {}).settings;
  assert.equal(s2.plugins[0].enabled, false);
  const r = U.revert(s2, LAMHA.id);
  assert.equal(r.ok, true);
  assert.deepEqual([r.settings.plugins[0].version, r.settings.plugins[0].enabled], ['1.0.0', true]);
  assert.equal(U.stateOf(r.settings, LAMHA.id).revoked, undefined);
  assert.equal(U.stateOf(r.settings, LAMHA.id).previousWithdrawn, undefined, 'a Revert clears the note with the rest');
  assert.equal(U.runnable(r.settings.plugins[0], U.stateOf(r.settings, LAMHA.id)).which, 'current');
});

test('the serial is remembered whenever it rises, so an older index cannot be replayed', () => {
  // Serial 9 lists 1.1.1. Serial 10 withdraws it before this shop ever took
  // it (it needs a newer Khayt here, so nothing else is written).
  const needs = { requires: { mac: '4.0.0-beta.40' } };
  const nine = index([row('1.1.1')], { serial: 9 });
  const ten = index([row('1.1.1', Object.assign({ revoked: [{ version: '1.1.1', reason: 'x' }] }, needs))], { serial: 10 });
  const s0 = book();
  const r10 = U.applyIndex(s0, ten, CTX, {});
  assert.deepEqual([r10.ok, r10.changed, r10.notes], [true, true, []]);
  assert.equal(onlySerial(s0, r10.settings), 10);
  // Someone serves serial 9 again: unexpired, properly signed, and refused.
  assert.deepEqual(U.fetchesFor(r10.settings, nine, CTX), []);
  const replay = U.applyIndex(r10.settings, nine, CTX, { [LAMHA.id]: at('1.1.1') });
  assert.deepEqual([replay.ok, replay.reason, replay.changed], [false, 'old_serial', false]);
  assert.equal(replay.settings, r10.settings);
  assert.equal(replay.settings.plugins[0].version, '1.0.0');
  // The serial never goes down, and the same one twice writes nothing.
  const again = U.applyIndex(r10.settings, ten, CTX, {});
  assert.deepEqual([again.changed, again.settings === r10.settings], [false, true]);
  // An index that fails the check does not move it either.
  const expired = index([row('1.1.1')], { serial: 11, expires: new Date(NOW - 1).toISOString(), issuedAt: new Date(NOW - 46 * DAY).toISOString() });
  assert.equal(U.applyIndex(r10.settings, expired, CTX, {}).settings, r10.settings);
  // A book with no connector at all still remembers it.
  assert.equal(U.applyIndex({ currency: 'SAR' }, ten, CTX, {}).settings.connectorUpdates.serial, 10);
});

/** A two-host connector: what goes to a.example.com, what to b, and where the key goes. */
function twoHost(version, toA, toB, authHost) {
  const act = (id, host, template) => Object.assign(
    { id, label: { en: id }, placement: 'order', kind: 'post', url: `https://${host}.example.com/x`, body: { format: 'json-template', template } },
    authHost === host ? { auth: { header: 'X-K', secret: 'key' } } : {});
  return { khayt: { manifest: 1 }, id: 'app.test.route', name: { en: 'Route' }, publisher: 'T', version,
           domains: ['a.example.com', 'b.example.com'], secrets: [{ name: 'key', label: { en: 'Key' }, kind: 'token' }],
           actions: [act('one', 'a', toA), act('two', 'b', toB)] };
}
const PERSON = { n: '{customer.name}', p: '{customer.phone}' };
const ORDER = { i: '{order.id}' };
/** The grant a build before pairs wrote: no `routes`. */
function legacyGrant(m) { const g = M.grantFor(m); return { version: g.version, fields: g.fields, domains: g.domains, scopes: g.scopes }; }
function legacyEntry(m) { return { id: m.id, version: m.version, enabled: true, manifest: m, granted: legacyGrant(m), config: {} }; }
const trow = (v) => ({ kind: 'connector', id: 'app.test.route', version: v, url: 'https://khaytapp.com/x.json', sha256: 'b'.repeat(64) });

test('an older grant on a two-host connector: a field or the key moving to the other host asks first', () => {
  const v1 = twoHost('1.0.0', PERSON, ORDER, 'a');
  assert.ok(M.validateManifest(v1).ok, M.validateManifest(v1).errors.join('; '));
  const entry = legacyEntry(v1);
  assert.deepEqual([M.checkEntry(entry).ok, M.checkEntry(entry).paused], [true, false], 'installed and running');
  // Read flat, the old grant allows the move (this is the hole).
  const fieldMoved = twoHost('1.1.0', ORDER, PERSON, 'a');
  const keyMoved = twoHost('1.1.0', PERSON, ORDER, 'b');
  assert.equal(M.diffPermissions(entry.granted, fieldMoved).widened, false);
  assert.equal(M.diffPermissions(entry.granted, keyMoved).widened, false);
  // An update is measured against what 1.0.0 really sent.
  const f = U.planWithManifest(entry, fieldMoved, trow('1.1.0'));
  assert.equal(f.plan, 'consent');
  assert.deepEqual([f.diff.fields, f.diff.domains], [[], []]);
  assert.deepEqual(f.diff.routes, ['a.example.com order.id', 'b.example.com customer.name', 'b.example.com customer.phone']);
  const k = U.planWithManifest(entry, keyMoved, trow('1.1.0'));
  assert.equal(k.plan, 'consent');
  assert.deepEqual(k.diff.routes, ['b.example.com secret:key']);
  // Over the whole book: the old version keeps running, the new one waits.
  const r = U.applyIndex({ plugins: [entry] }, index([trow('1.1.0')]), CTX, { 'app.test.route': fieldMoved });
  assert.deepEqual(r.notes.map((n) => n.kind), ['pending']);
  assert.deepEqual(r.settings.plugins[0], entry);
});

test('an older grant gains its pairs on its first automatic update, and is an old grant only once', () => {
  const v1 = twoHost('1.0.0', PERSON, ORDER, 'a');
  const entry = legacyEntry(v1);
  // Same pairs, a new version: by itself.
  const same = twoHost('1.1.0', PERSON, ORDER, 'a');
  assert.equal(U.planWithManifest(entry, same, trow('1.1.0')).plan, 'auto');
  const r = U.applyIndex({ plugins: [entry] }, index([trow('1.1.0')]), CTX, { 'app.test.route': same });
  const e = r.settings.plugins[0];
  assert.deepEqual(e.granted.routes, M.permissionsOf(v1).routes, 'what 1.0.0 sent — not every field to every host');
  assert.deepEqual(e.granted.routes, ['a.example.com customer.name', 'a.example.com customer.phone', 'a.example.com secret:key', 'b.example.com order.id']);
  assert.deepEqual([e.granted.fields, e.granted.domains, e.granted.scopes], [entry.granted.fields, entry.granted.domains, entry.granted.scopes]);
  assert.deepEqual(M.checkEntry(e), { ok: true, errors: [], paused: false });
  assert.deepEqual(Object.keys(e).sort(), ['config', 'enabled', 'granted', 'id', 'manifest', 'version'], 'only keys every shipped build accepts');
  // From here the move is refused by the grant itself, on any build that reads pairs.
  assert.equal(M.diffPermissions(e.granted, twoHost('1.2.0', ORDER, PERSON, 'a')).widened, true);
  assert.equal(M.diffPermissions(e.granted, twoHost('1.2.0', PERSON, ORDER, 'b')).widened, true);
  // The entry passed in is not edited, and Revert puts the old grant back whole.
  assert.equal(entry.granted.routes, undefined);
  assert.deepEqual(U.revert(r.settings, 'app.test.route').settings.plugins[0], entry);
  // An installed manifest that already asked for more than the old grant lists gives no pair for it.
  const greedy = Object.assign(legacyEntry(v1), { granted: Object.assign(legacyGrant(v1), { fields: ['customer.name', 'order.id'] }) });
  assert.deepEqual(U.grantWithPairs(greedy).routes, ['a.example.com customer.name', 'a.example.com secret:key', 'b.example.com order.id']);
  // A grant that has pairs is handed back as it is.
  assert.equal(U.grantWithPairs(e), e.granted);
});

test('an update that sends LESS installs by itself and leaves an entry every build accepts', () => {
  // Found on Nov 11: the grant kept customer.email after the manifest dropped
  // it, and checkEntry refuses a grant the manifest does not declare.
  for (const grant of [M.grantFor(at('1.0.0')), legacyGrant(at('1.0.0'))]) {
    const s0 = book(installed('1.0.0', grant));
    const less = narrow('1.1.0');
    assert.equal(U.planWithManifest(s0.plugins[0], less, row('1.1.0')).plan, 'auto');
    const r = U.applyIndex(s0, index([row('1.1.0')]), CTX, { [LAMHA.id]: less });
    const e = r.settings.plugins[0];
    assert.deepEqual(M.checkEntry(e), { ok: true, errors: [], paused: false });
    assert.equal(e.granted.fields.includes('customer.email'), false);
    assert.equal(e.granted.routes.some((x) => x.endsWith(' customer.email')), false);
    assert.ok(e.granted.fields.every((x) => grant.fields.includes(x)), 'narrowed, never widened');
    // The fuller version after it has to ask again: the email is no longer granted.
    assert.equal(U.planWithManifest(e, at('1.2.0'), row('1.2.0')).plan, 'consent');
    assert.deepEqual(U.revert(r.settings, LAMHA.id).settings.plugins[0].granted, grant, 'Revert: the grant as it was');
  }
});

test('a grant may not list a pair the manifest does not send', () => {
  const e = installed('1.0.0');
  assert.equal(M.checkEntry(e).ok, true);
  const widened = Object.assign({}, e, { granted: Object.assign({}, e.granted, { routes: e.granted.routes.concat(['evil.example.com customer.phone']) }) });
  const c = M.checkEntry(widened);
  assert.deepEqual([c.ok, c.paused], [false, true]);
  assert.ok(c.errors.some((x) => x.startsWith('granted.routes: evil.example.com customer.phone')));
  // Fewer pairs than the manifest sends is a narrower grant: paused, not invalid.
  const fewer = Object.assign({}, e, { granted: Object.assign({}, e.granted, { routes: e.granted.routes.slice(1) }) });
  assert.deepEqual([M.checkEntry(fewer).ok, M.checkEntry(fewer).paused], [true, true]);
});

test('the manifest format a device reads is one exported number, the one the manifest validator holds', () => {
  assert.equal(U.SCHEMA, 1);
  assert.equal(U.SCHEMA, LAMHA.khayt.manifest);
  assert.equal(U.planUpdate(installed('1.0.0'), {}, row('1.1.1', { requires: { schema: U.SCHEMA } }), Object.assign({}, CTX, { schema: U.SCHEMA })).plan, 'fetch');
  assert.equal(U.planUpdate(installed('1.0.0'), {}, row('1.1.1', { requires: { schema: U.SCHEMA + 1 } }), Object.assign({}, CTX, { schema: U.SCHEMA })).plan, 'blocked');
});

test('a key is forgotten when the hosts its secret goes to change, and only that key', () => {
  const two = (toA, toB) => ({ khayt: { manifest: 1 }, id: 'app.test.keys', name: { en: 'Keys' }, publisher: 'T', version: '1.0.0',
    domains: ['a.example.com', 'b.example.com'],
    secrets: [{ name: 'one', label: { en: 'One' }, kind: 'token' }, { name: 'two', label: { en: 'Two' }, kind: 'token' }],
    actions: [
      Object.assign({ id: 'a', label: { en: 'A' }, placement: 'order', kind: 'post', url: 'https://a.example.com/x', body: { format: 'json-template', template: { i: '{order.id}' } } }, toA ? { auth: { header: 'X-K', secret: toA } } : {}),
      Object.assign({ id: 'b', label: { en: 'B' }, placement: 'order', kind: 'post', url: 'https://b.example.com/y', body: { format: 'json-template', template: { i: '{order.id}' } } }, toB ? { auth: { header: 'X-K', secret: toB } } : {}),
    ] });
  const v1 = two('one', 'two');
  assert.ok(M.validateManifest(v1).ok, M.validateManifest(v1).errors.join('; '));
  const g1 = M.grantFor(v1);
  assert.deepEqual(g1.routes.filter((r) => r.includes(' secret:')), ['a.example.com secret:one', 'b.example.com secret:two']);
  // The same grant, or one that differs in nothing about keys: nothing forgotten.
  assert.deepEqual(U.secretsToForget(g1, g1), { all: false, names: [] });
  assert.deepEqual(U.secretsToForget(g1, Object.assign({}, g1, { fields: [], routes: g1.routes.filter((r) => r.includes(' secret:')) })), { all: false, names: [] });
  // `one` now also goes to b: `one` is forgotten, `two` keeps its key.
  const also = Object.assign({}, g1, { routes: g1.routes.concat(['b.example.com secret:one']) });
  assert.deepEqual(U.secretsToForget(g1, also), { all: false, names: ['one'] });
  // The two keys swap hosts: both.
  assert.deepEqual(U.secretsToForget(g1, M.grantFor(two('two', 'one'))), { all: false, names: ['one', 'two'] });
  // A Revert is the same question the other way round.
  assert.deepEqual(U.secretsToForget(also, g1), { all: false, names: ['one'] });
  // A secret that stops being sent, or starts: its hosts changed.
  assert.deepEqual(U.secretsToForget(g1, M.grantFor(two('one', null))), { all: false, names: ['two'] });
  assert.deepEqual(U.secretsToForget(M.grantFor(two('one', null)), g1), { all: false, names: ['two'] });
  // A grant from before pairs were kept: any change of hosts is a change for every key.
  const legacy = { version: g1.version, fields: g1.fields, domains: g1.domains, scopes: g1.scopes };
  assert.deepEqual(U.secretsToForget(legacy, g1), { all: false, names: [] }, 'same hosts: nothing is known to have moved');
  assert.deepEqual(U.secretsToForget(legacy, Object.assign({}, g1, { domains: ['a.example.com'] })), { all: true, names: [] });
  assert.deepEqual(U.secretsToForget(g1, Object.assign({}, legacy, { domains: g1.domains.concat(['c.example.com']) })), { all: true, names: [] });
  assert.deepEqual(U.secretsToForget(legacy, Object.assign({}, legacy, { domains: g1.domains.slice().reverse() })), { all: false, names: [] }, 'order is not a change');
  // Nothing to compare is nothing to forget.
  assert.deepEqual(U.secretsToForget(null, null), { all: false, names: [] });
  // Over a real update: Lamha 1.0.0 narrow → 1.1.1 keeps its one key (same host).
  assert.deepEqual(U.secretsToForget(M.grantFor(narrow('1.0.0')), M.grantFor(at('1.1.1'))), { all: false, names: [] });
});

test('over two entries: an older grant is read by what its manifest sends, so a key moved between listed hosts is forgotten', () => {
  const v1 = twoHost('1.0.0', PERSON, ORDER, 'a');
  const moved = twoHost('1.1.0', PERSON, ORDER, 'b');
  const before = legacyEntry(v1);
  const after = { id: moved.id, version: moved.version, enabled: true, manifest: moved, granted: M.grantFor(moved), config: {} };
  assert.deepEqual(U.secretsToForget(before.granted, after.granted), { all: false, names: [] }, 'the grants alone cannot tell');
  assert.deepEqual(U.keysToForget(before, after), ['key']);
  assert.deepEqual(U.keysToForget(after, before), ['key'], 'and back again on Revert');
  // Same pairs: the key stays.
  const same = twoHost('1.1.0', PERSON, ORDER, 'a');
  assert.deepEqual(U.keysToForget(before, { id: same.id, version: same.version, enabled: true, manifest: same, granted: M.grantFor(same), config: {} }), []);
  // Nothing readable on one side and the hosts differ: every declared secret.
  assert.deepEqual(U.keysToForget({ id: v1.id, manifest: v1, granted: null }, after), ['key']);
  assert.deepEqual(U.keysToForget(null, null), []);
  // Lamha's own update keeps its key.
  assert.deepEqual(U.keysToForget(installedNarrow(), installed('1.1.1')), []);
});
