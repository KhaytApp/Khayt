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

test('blocked is told, and nothing is written', () => {
  const s0 = book();
  const r = U.applyIndex(s0, index([row('1.1.1', { requires: { mac: '4.0.0-beta.40' } })]), CTX, {});
  assert.equal(r.settings, s0);
  assert.deepEqual(r.notes, [{ id: LAMHA.id, kind: 'blocked', from: '1.0.0', to: '1.1.1', needs: { app: '4.0.0-beta.40' } }]);
});

test('a download that failed is simply tried again: nothing written', () => {
  const s0 = book();
  const r = U.applyIndex(s0, index([row('1.1.1')]), CTX, {});
  assert.equal(r.settings, s0);
  assert.equal(r.changed, false);
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
