/**
 * Org Data Key: the v1 → v2 keyset migration and the `wrappedByOrg` slot.
 * See docs/KHAYT-3.0-ORG-DATA-KEY.md, "What to build, in order" steps 2 and 3.
 *
 * The suite in test/sync-crypto.test.js already covers the envelope itself
 * (wrong passphrase, wrong recovery key, wrong DEK, tampering, changePassphrase,
 * desktop↔web). This one is deliberately about what the org changes, and its
 * centre of gravity is the NEGATIVE cases — a too-permissive unwrap is the exact
 * silent failure the design doc is written around, and it is the only failure
 * here that would never announce itself.
 *
 * Low scrypt cost (FAST_KDF) for speed; production keysets carry their own
 * params, so this affects test runtime, not the contract.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const sc = require('../lib/sync-crypto.js');

const FAST_KDF = { algo: 'scrypt', N: 1024, r: 8, p: 1, keyLen: 32 };
const mk = (pass) => sc.createKeyset(pass, { kdf: FAST_KDF });
const mkOrg = (pass) => sc.createOrgKeyset(pass, { kdf: FAST_KDF });
const STORE = { printLog: [{ id: 'o1', price: 100 }], clients: [{ id: 'c1', name: 'سارة' }] };

/**
 * A keyset exactly as v3.4.1 and earlier wrote it: version 1, two slots, no org.
 * Built by stripping the fields v2 added rather than by hand, so it stays a real
 * keyset (real salts, real wraps) and cannot drift away from what shipped.
 */
function v1Keyset(passphrase) {
  const { keyset, recoveryKey } = mk(passphrase);
  const { wrappedByOrg, ...rest } = keyset;
  return { keyset: { ...rest, version: 1 }, recoveryKey };
}

// ── Step 2: the migration must change nothing for a shop that is not in an org ─

test('a v1 keyset still opens on every path, unchanged, against v2 code', () => {
  const { keyset, recoveryKey } = v1Keyset('old-shop-pass');
  assert.equal(keyset.version, 1);
  assert.equal(keyset.wrappedByOrg, undefined);

  const dekP = sc.unlockWithPassphrase('old-shop-pass', keyset);
  const dekR = sc.unlockWithRecovery(recoveryKey, keyset);
  assert.deepEqual(dekP, dekR, 'both v1 slots still yield the same DEK');

  // and the wrong-secret checks still bite on a v1 keyset
  assert.throws(() => sc.unlockWithPassphrase('wrong', keyset));
  assert.throws(() => sc.unlockWithRecovery('AAAA-BBBB-CCCC-DDDD', keyset));

  const blob = sc.encryptStore(STORE, dekP);
  assert.deepEqual(sc.decryptStore(blob, dekR), STORE);
});

test('a store blob written before the split still decrypts, and still reads v1', () => {
  // The blob format did not change, which is the entire reason the two version
  // constants were split. A blob as v1 wrote it (an explicit `v: 1` stamp, same
  // AES-256-GCM body) must round-trip, and what v2 writes must be that same v1.
  const { keyset } = v1Keyset('shop');
  const dek = sc.unlockWithPassphrase('shop', keyset);

  // EXPLICITLY uncompressed: this test reconstructs what v1 wrote, and v1 had no
  // compression. Taking the default here would strip the `z` marker off a gzip
  // body and assert on a shape nothing ever produced.
  const fresh = sc.encryptStore(STORE, dek, { compress: false });
  assert.equal(fresh.v, 1, 'v2 code still stamps store blobs v1');
  assert.deepEqual(sc.decryptStore(fresh, dek), STORE);

  const asV1Wrote = { v: 1, iv: fresh.iv, ct: fresh.ct, tag: fresh.tag };
  assert.deepEqual(sc.decryptStore(asV1Wrote, dek), STORE);
});

test('encryptStore stamps the blob version, not the keyset version', () => {
  // The two used to be one constant. If they are ever re-merged, bumping the
  // keyset would silently relabel every store blob as a format that does not
  // exist — a corruption no user could diagnose, on data they cannot re-derive.
  assert.equal(sc.KEYSET_VERSION, 2);
  assert.equal(sc.STORE_BLOB_VERSION, 1);
  assert.notEqual(sc.KEYSET_VERSION, sc.STORE_BLOB_VERSION);

  const { keyset } = mk('p');
  const dek = sc.unlockWithPassphrase('p', keyset);
  assert.equal(sc.encryptStore(STORE, dek).v, sc.STORE_BLOB_VERSION);
});

test('desktop and web stamp store blobs with the same version', () => {
  // The phone reads what the desktop writes. These are separate files with
  // separate constants; nothing but a test keeps them in step.
  const web = require('../lib/sync-crypto-web.js');
  const src = require('node:fs').readFileSync(require.resolve('../lib/sync-crypto-web.js'), 'utf8');
  const m = src.match(/const STORE_BLOB_VERSION = (\d+);/);
  assert.ok(m, 'web twin declares STORE_BLOB_VERSION');
  assert.equal(Number(m[1]), sc.STORE_BLOB_VERSION);
  assert.equal(typeof web.encryptStore, 'function');
});

test('a fresh keyset is v2 and carries no org slot until it joins one', () => {
  const { keyset } = mk('brand-new');
  assert.equal(keyset.version, 2, 'the version describes the format...');
  assert.equal(keyset.wrappedByOrg, undefined, '...not the contents');
});

// ── Step 3: wrappedByOrg and the org keyset ──────────────────────────────────

test('one org passphrase opens two different shops', () => {
  const { orgKeyset, orgKey } = mkOrg('org-pass');
  const shops = ['riyadh', 'jeddah'].map((name) => {
    const { keyset } = mk(`${name}-pass`);
    const dek = sc.unlockWithPassphrase(`${name}-pass`, keyset);
    return { name, dek, keyset: sc.joinOrg(keyset, dek, orgKey, orgKeyset.orgId) };
  });

  // What a second machine actually does: unlock the org once, open every branch.
  const odk = sc.unlockOrgWithPassphrase('org-pass', orgKeyset);
  for (const shop of shops) {
    const blob = sc.encryptStore({ ...STORE, branch: shop.name }, shop.dek);
    const viaOrg = sc.unlockWithOrg(odk, orgKeyset.orgId, shop.keyset);
    assert.deepEqual(viaOrg, shop.dek, `${shop.name}: the ODK yields that shop's own DEK`);
    assert.equal(sc.decryptStore(blob, viaOrg).branch, shop.name);
  }

  // DEKs stay per-shop: holding one branch's key must not open the other.
  assert.notDeepEqual(shops[0].dek, shops[1].dek);
  const otherBlob = sc.encryptStore(STORE, shops[1].dek);
  assert.throws(() => sc.decryptStore(otherBlob, shops[0].dek));
});

test('NEGATIVE: a shop outside the org does not open under the ODK', () => {
  const { orgKeyset, orgKey } = mkOrg('org-pass');
  const { keyset: outsider } = mk('outsider-pass');
  assert.throws(
    () => sc.unlockWithOrg(orgKey, orgKeyset.orgId, outsider),
    /not part of an organisation/,
  );
});

test('NEGATIVE: another org\'s ODK does not open this org\'s shop', () => {
  const a = mkOrg('org-a');
  const b = mkOrg('org-b');
  const { keyset } = mk('shop');
  const dek = sc.unlockWithPassphrase('shop', keyset);
  const member = sc.joinOrg(keyset, dek, a.orgKey, a.orgKeyset.orgId);

  // Caught by the label...
  assert.throws(
    () => sc.unlockWithOrg(b.orgKey, b.orgKeyset.orgId, member),
    /different organisation/,
  );
  // ...and, with the label forged to match, still caught by GCM. This is the
  // one that matters: the orgId is a diagnostic, the auth tag is the boundary.
  const forged = { ...member, wrappedByOrg: { ...member.wrappedByOrg, orgId: b.orgKeyset.orgId } };
  assert.throws(() => sc.unlockWithOrg(b.orgKey, b.orgKeyset.orgId, forged));
});

test('NEGATIVE: a tampered wrappedByOrg is rejected', () => {
  const { orgKeyset, orgKey } = mkOrg('org-pass');
  const { keyset } = mk('shop');
  const dek = sc.unlockWithPassphrase('shop', keyset);
  const member = sc.joinOrg(keyset, dek, orgKey, orgKeyset.orgId);

  const ct = Buffer.from(member.wrappedByOrg.ct, 'base64');
  ct[0] ^= 0xff;
  const tampered = {
    ...member,
    wrappedByOrg: { ...member.wrappedByOrg, ct: ct.toString('base64') },
  };
  assert.throws(() => sc.unlockWithOrg(orgKey, orgKeyset.orgId, tampered));
});

test('NEGATIVE: unlockWithOrg refuses to run without an orgId', () => {
  // An optional argument that silently skips a check is the shape of bug this
  // module cannot afford, so the check is not optional.
  const { orgKeyset, orgKey } = mkOrg('org-pass');
  const { keyset } = mk('shop');
  const dek = sc.unlockWithPassphrase('shop', keyset);
  const member = sc.joinOrg(keyset, dek, orgKey, orgKeyset.orgId);

  for (const bad of [undefined, null, '', 0]) {
    assert.throws(() => sc.unlockWithOrg(orgKey, bad, member), /orgId required/);
  }
  assert.deepEqual(sc.unlockWithOrg(orgKey, orgKeyset.orgId, member), dek);
});

test('joining an org changes nothing about how the shop already opened', () => {
  // The promise made to an existing owner: a recovery key already printed and
  // filed keeps working, and the passphrase they know keeps working.
  const { keyset: before, recoveryKey } = v1Keyset('shop-pass');
  const dek = sc.unlockWithPassphrase('shop-pass', before);
  const blob = sc.encryptStore(STORE, dek);

  const { orgKeyset, orgKey } = mkOrg('org-pass');
  const after = sc.joinOrg(before, dek, orgKey, orgKeyset.orgId);

  assert.equal(after.version, 2, 'v1 → v2 happens here, when a slot is actually added');
  assert.deepEqual(after.wrappedByPassphrase, before.wrappedByPassphrase, 'slot untouched');
  assert.deepEqual(after.wrappedByRecovery, before.wrappedByRecovery, 'slot untouched');
  assert.deepEqual(sc.unlockWithPassphrase('shop-pass', after), dek);
  assert.deepEqual(sc.unlockWithRecovery(recoveryKey, after), dek, 'the printed key still works');
  assert.deepEqual(sc.decryptStore(blob, dek), STORE, 'no re-encryption: the DEK never moved');
  assert.equal(before.wrappedByOrg, undefined, 'joinOrg did not mutate the caller\'s keyset');
});

test('leaving an org closes the ODK path and leaves the shop\'s own intact', () => {
  const { orgKeyset, orgKey } = mkOrg('org-pass');
  const { keyset, recoveryKey } = mk('shop-pass');
  const dek = sc.unlockWithPassphrase('shop-pass', keyset);
  const member = sc.joinOrg(keyset, dek, orgKey, orgKeyset.orgId);
  const left = sc.leaveOrg(member);

  assert.throws(() => sc.unlockWithOrg(orgKey, orgKeyset.orgId, left), /not part of an organisation/);
  assert.deepEqual(sc.unlockWithPassphrase('shop-pass', left), dek, 'the owner is not locked out');
  assert.deepEqual(sc.unlockWithRecovery(recoveryKey, left), dek);
});

test('the org recovery key opens the org, and the wrong one does not', () => {
  const { orgKeyset, orgKey, recoveryKey } = mkOrg('org-pass');
  assert.deepEqual(sc.unlockOrgWithRecovery(recoveryKey, orgKeyset), orgKey);
  assert.deepEqual(sc.unlockOrgWithPassphrase('org-pass', orgKeyset), orgKey);
  assert.throws(() => sc.unlockOrgWithPassphrase('nope', orgKeyset));
  assert.throws(() => sc.unlockOrgWithRecovery('AAAA-BBBB-CCCC-DDDD', orgKeyset));
});

test('changing the org passphrase re-wraps nothing but the ODK', () => {
  const { orgKeyset, orgKey, recoveryKey } = mkOrg('org-old');
  const { keyset } = mk('shop');
  const dek = sc.unlockWithPassphrase('shop', keyset);
  const member = sc.joinOrg(keyset, dek, orgKey, orgKeyset.orgId);

  const rotated = sc.changeOrgPassphrase(orgKeyset, 'org-old', 'org-new');
  assert.throws(() => sc.unlockOrgWithPassphrase('org-old', rotated));
  const odk = sc.unlockOrgWithPassphrase('org-new', rotated);
  assert.deepEqual(odk, orgKey, 'the ODK itself did not change...');
  assert.deepEqual(sc.unlockWithOrg(odk, rotated.orgId, member), dek, '...so members still open');
  assert.deepEqual(sc.unlockOrgWithRecovery(recoveryKey, rotated), orgKey, 'recovery survives');
});

// ── The key-wrapping primitives ──────────────────────────────────────────────

test('the org keyset carries no usable key, exactly like a shop keyset', () => {
  // The claim the whole product rests on, restated for the new artefact: the
  // org keyset is server-safe. Fail loudly if the ODK ever leaks into it.
  const { orgKeyset, orgKey, recoveryKey } = mkOrg('org-pass');
  const serialized = JSON.stringify(orgKeyset);
  assert.ok(!serialized.includes(orgKey.toString('base64')), 'no ODK in the keyset');
  assert.ok(!serialized.includes('org-pass'), 'no passphrase in the keyset');
  assert.ok(!serialized.includes(recoveryKey.replace(/-/g, '')), 'no recovery key in the keyset');
  assert.ok(!serialized.includes(recoveryKey));
});

test('key wrapping uses no KDF and no salt, and says so in the entry', () => {
  // The ODK is already 256 uniform random bits; scrypt over it would cost 32 MB
  // and ~100 ms per unwrap to add nothing. The `kek: 'direct'` marker keeps the
  // shape self-describing so the two paths cannot be confused.
  const key = crypto.randomBytes(32);
  const secret = crypto.randomBytes(32);
  const wrapped = sc.wrapWithKey(secret, key);
  assert.equal(wrapped.kek, 'direct');
  assert.equal(wrapped.salt, undefined);
  assert.deepEqual(sc.unwrapWithKey(key, wrapped), secret);
  assert.throws(() => sc.unwrapWithKey(crypto.randomBytes(32), wrapped));
});

test('the two wrapping paths refuse each other\'s entries', () => {
  // Without the guard, feeding a key-wrapped entry to unwrapDek would derive a
  // KEK from an empty salt buffer and fail with a GCM error that names nothing.
  const key = crypto.randomBytes(32);
  const keyWrapped = sc.wrapWithKey(crypto.randomBytes(32), key);
  assert.throws(() => sc.unwrapDek('pass', keyWrapped, FAST_KDF), /key-wrapped/);

  const passWrapped = sc.wrapDek(crypto.randomBytes(32), 'pass', FAST_KDF);
  assert.throws(() => sc.unwrapWithKey(key, passWrapped), /not a key-wrapped entry/);
});

test('key wrapping rejects anything that is not a 32-byte key', () => {
  const secret = crypto.randomBytes(32);
  for (const bad of [undefined, null, 'a-string-of-32-characters-here!!', crypto.randomBytes(16), 42]) {
    assert.throws(() => sc.wrapWithKey(secret, bad), /32 raw bytes/);
  }
  const wrapped = sc.wrapWithKey(secret, crypto.randomBytes(32));
  assert.throws(() => sc.unwrapWithKey('not-a-buffer', wrapped), /32 raw bytes/);
});

test('joinOrg rejects a DEK that is not 32 raw bytes', () => {
  const { orgKeyset, orgKey } = mkOrg('org-pass');
  const { keyset } = mk('shop');
  assert.throws(() => sc.joinOrg(keyset, 'a-dek', orgKey, orgKeyset.orgId), /32 raw bytes/);
  assert.throws(() => sc.joinOrg(keyset, crypto.randomBytes(16), orgKey, orgKeyset.orgId), /32 raw bytes/);
  assert.throws(() => sc.joinOrg(null, crypto.randomBytes(32), orgKey, orgKeyset.orgId), /keyset required/);
  assert.throws(() => sc.joinOrg(keyset, crypto.randomBytes(32), orgKey, ''), /orgId required/);
});

test('two orgs get different ids and different keys', () => {
  const a = mkOrg('same-passphrase');
  const b = mkOrg('same-passphrase');
  assert.notEqual(a.orgKeyset.orgId, b.orgKeyset.orgId);
  assert.notDeepEqual(a.orgKey, b.orgKey, 'the ODK is random, not derived from the passphrase');
});
